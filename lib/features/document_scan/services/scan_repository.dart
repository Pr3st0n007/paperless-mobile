import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:path/path.dart' as p;
import 'package:uuid/uuid.dart';

/// Rendered JPEGs stay compatible with scans created by the old scanner.
/// Originals and edit recipes live separately and are never uploaded.
class ScanRepository {
  final Directory directory;

  ScanRepository(this.directory);

  File _original(File scan) =>
      File(p.join(directory.path, 'originals', p.basename(scan.path)));
  File _recipe(File scan) => File(
    p.join(directory.path, 'originals', '${p.basename(scan.path)}.json'),
  );
  File get _order => File(p.join(directory.path, 'order.json'));

  Future<List<File>> restore() async {
    await directory.create(recursive: true);
    final scans = <File>[];
    await for (final entity in directory.list()) {
      if (entity is File && entity.path.endsWith('.jpeg')) {
        if (await entity.length() == 0) {
          await entity.delete();
        } else {
          scans.add(entity);
        }
      }
    }
    final order = await _order.exists()
        ? (jsonDecode(await _order.readAsString()) as List).cast<String>()
        : <String>[];
    final positions = {for (var i = 0; i < order.length; i++) order[i]: i};
    scans.sort((a, b) {
      final ai = positions[p.basename(a.path)];
      final bi = positions[p.basename(b.path)];
      if (ai != null || bi != null) {
        return (ai ?? order.length).compareTo(bi ?? order.length);
      }
      return p.basename(a.path).compareTo(p.basename(b.path));
    });
    return scans;
  }

  Future<Uint8List> readOriginal(File scan) async {
    final original = _original(scan);
    return await original.exists()
        ? original.readAsBytes()
        : scan.readAsBytes();
  }

  Future<ScanEdit?> readEdit(File scan) async {
    final recipe = _recipe(scan);
    if (!await recipe.exists()) return null;
    return ScanEdit.fromJson(
      jsonDecode(await recipe.readAsString()) as Map<String, dynamic>,
    );
  }

  Future<File> save({
    required Uint8List original,
    required Uint8List rendered,
    required ScanEdit edit,
    File? replacing,
  }) async {
    final scan =
        replacing ?? File(p.join(directory.path, '${const Uuid().v1()}.jpeg'));
    await _original(scan).parent.create(recursive: true);
    // Keep the source before replacing a legacy scan for the first time.
    if (!await _original(scan).exists()) {
      await _writeAtomic(_original(scan), original);
    }
    await _writeAtomic(_recipe(scan), utf8.encode(jsonEncode(edit.toJson())));
    await _writeAtomic(scan, rendered);
    return scan;
  }

  Future<void> saveOrder(List<File> scans) => _writeAtomic(
    _order,
    utf8.encode(jsonEncode(scans.map((f) => p.basename(f.path)).toList())),
  );

  Future<void> delete(File scan) async {
    for (final file in [scan, _original(scan), _recipe(scan)]) {
      if (await file.exists()) await file.delete();
    }
  }

  Future<void> _writeAtomic(File target, List<int> bytes) async {
    await target.parent.create(recursive: true);
    final staging = File('${target.path}.pending');
    await staging.writeAsBytes(bytes, flush: true);
    await staging.rename(target.path);
  }
}
