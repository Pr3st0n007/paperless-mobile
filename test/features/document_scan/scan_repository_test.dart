import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:logger/logger.dart';
import 'package:paperless_mobile/features/document_scan/cubit/document_scanner_cubit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_repository.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';
import 'package:paperless_mobile/features/notifications/services/local_notification_service.dart';

class _Notifications extends Fake implements LocalNotificationService {}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory directory;
  late ScanRepository repository;
  final original = Uint8List.fromList([1, 2, 3]);
  final rendered = Uint8List.fromList([4, 5, 6]);
  final edit = ScanEdit(corners: ScanEdit.fullPage);

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('paperless_scan_test_');
    repository = ScanRepository(directory);
    logger = Logger(level: Level.off);
  });
  tearDown(() => directory.delete(recursive: true));

  Future<File> save() =>
      repository.save(original: original, rendered: rendered, edit: edit);

  test(
    'restores legacy scans, skips originals and removes empty scans',
    () async {
      final legacy = await File('${directory.path}/old.jpeg').writeAsBytes([1]);
      final empty = await File('${directory.path}/empty.jpeg').create();
      final scan = await save();
      final restored = await repository.restore();
      expect(
        restored.map((f) => f.path),
        containsAll([scan.path, legacy.path]),
      );
      expect(restored.length, 2);
      expect(await empty.exists(), isFalse);
      expect(await repository.readOriginal(legacy), [1]);
      expect(await repository.readEdit(legacy), isNull);
    },
  );

  test('editing always uses the untouched original', () async {
    final scan = await save();
    await repository.save(
      original: original,
      rendered: Uint8List.fromList([7, 8, 9]),
      edit: edit.copyWith(filter: ScanFilter.blackAndWhite, quarterTurns: 1),
      replacing: scan,
    );
    expect(await repository.readOriginal(scan), original);
    expect(await scan.readAsBytes(), [7, 8, 9]);
    final recipe = await repository.readEdit(scan);
    expect(recipe!.filter, ScanFilter.blackAndWhite);
    expect(recipe.quarterTurns, 1);
    expect((await repository.restore()).length, 1);
  });

  test('retaking replaces the original while preserving page identity', () async {
    final scan = await save();
    final replacementOriginal = Uint8List.fromList([9, 8, 7]);
    await repository.save(
      original: replacementOriginal,
      rendered: Uint8List.fromList([6, 5, 4]),
      edit: edit,
      replacing: scan,
      replaceOriginal: true,
    );
    expect(await repository.readOriginal(scan), replacementOriginal);
    expect(await scan.readAsBytes(), [6, 5, 4]);
    expect((await repository.restore()).single.path, scan.path);
  });

  test(
    'page ordering survives restart, including newly discovered scans',
    () async {
      final first = await save();
      final second = await save();
      await repository.saveOrder([second, first]);
      final third = await save();
      final restored = await ScanRepository(directory).restore();
      expect(restored.map((f) => f.path), [
        second.path,
        first.path,
        third.path,
      ]);
    },
  );

  test('corrupt ordering and edit recipes surface an error', () async {
    final scan = await save();
    await File('${directory.path}/order.json').writeAsString('not JSON');
    await expectLater(repository.restore(), throwsFormatException);
    await File(
      '${directory.path}/originals/${scan.uri.pathSegments.last}.json',
    ).writeAsString('not JSON');
    await expectLater(repository.readEdit(scan), throwsFormatException);
  });

  test(
    'cubit persists reordering and awaits deletion of all scan assets',
    () async {
      final cubit = DocumentScannerCubit(
        _Notifications(),
        repository: repository,
      );
      addTearDown(cubit.close);
      await cubit.initialize();
      for (var i = 0; i < 2; i++) {
        await cubit.saveScan(
          original: original,
          rendered: rendered,
          edit: edit,
        );
      }
      final first = cubit.state.scans.first;
      final second = cubit.state.scans.last;
      await cubit.moveScan(second, -1);
      expect(cubit.state.scans, [second, first]);
      expect((await repository.restore()).map((f) => f.path), [
        second.path,
        first.path,
      ]);
      final revision = cubit.state.revision;
      await cubit.saveScan(
        original: original,
        rendered: rendered,
        edit: edit,
        replacing: first,
      );
      expect(cubit.state.revision, greaterThan(revision));
      await cubit.reset();
      expect(cubit.state.scans, isEmpty);
      expect(await repository.restore(), isEmpty);
      expect(
        await Directory('${directory.path}/originals').list().toList(),
        isEmpty,
      );
    },
  );

  test('scan-wide format changes non-overridden pages only', () async {
    final cubit = DocumentScannerCubit(
      _Notifications(),
      repository: repository,
    );
    addTearDown(cubit.close);
    await cubit.initialize();
    final image = img.Image(width: 80, height: 120);
    img.fill(image, color: img.ColorRgb8(240, 240, 240));
    img.drawLine(
      image,
      x1: 10,
      y1: 20,
      x2: 70,
      y2: 20,
      color: img.ColorRgb8(20, 20, 20),
    );
    final bytes = Uint8List.fromList(img.encodeJpg(image));
    final defaultEdit = ScanEdit(
      corners: ScanEdit.fullPage,
      filter: ScanFilter.color,
    );
    await cubit.saveScan(
      original: bytes,
      rendered: DocumentProcessor.render(
        ScanRenderRequest(bytes, defaultEdit),
      ),
      edit: defaultEdit,
    );
    final override = defaultEdit.copyWith(
      pageFormat: ScanPageFormat.a4,
      formatOverride: true,
    );
    await cubit.saveScan(
      original: bytes,
      rendered: DocumentProcessor.render(ScanRenderRequest(bytes, override)),
      edit: override,
    );

    await cubit.setScanFormat(ScanPageFormat.letter);
    final firstEdit = await repository.readEdit(cubit.state.scans[0]);
    final secondEdit = await repository.readEdit(cubit.state.scans[1]);
    expect(firstEdit!.pageFormat, ScanPageFormat.letter);
    expect(firstEdit.formatOverride, isFalse);
    expect(secondEdit!.pageFormat, ScanPageFormat.a4);
    expect(secondEdit.formatOverride, isTrue);
    expect(await repository.readScanFormat(), ScanPageFormat.letter);
  });
}
