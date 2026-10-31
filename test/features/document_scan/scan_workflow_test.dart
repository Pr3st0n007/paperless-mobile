import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_capture_page.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

class _Camera extends CameraPlatform {
  final File capture;
  final bool denied;
  int created = 0;
  int disposed = 0;
  bool? audioEnabled;
  FlashMode? flash;
  Point<double>? focus;
  Point<double>? exposure;

  _Camera(this.capture, {this.denied = false});

  @override
  Future<List<CameraDescription>> availableCameras() async {
    if (denied) throw CameraException('CameraAccessDenied', 'Access denied');
    return [
      const CameraDescription(
        name: 'rear',
        lensDirection: CameraLensDirection.back,
        sensorOrientation: 90,
      ),
    ];
  }

  @override
  Future<int> createCamera(
    CameraDescription cameraDescription,
    ResolutionPreset? resolutionPreset, {
    bool enableAudio = false,
  }) async {
    audioEnabled = enableAudio;
    return ++created;
  }

  @override
  Future<void> initializeCamera(
    int cameraId, {
    ImageFormatGroup imageFormatGroup = ImageFormatGroup.unknown,
  }) async {}

  @override
  Stream<CameraInitializedEvent> onCameraInitialized(int cameraId) =>
      Stream.value(
        CameraInitializedEvent(
          cameraId,
          640,
          480,
          ExposureMode.auto,
          true,
          FocusMode.auto,
          true,
        ),
      );

  @override
  Stream<CameraErrorEvent> onCameraError(int cameraId) =>
      Stream<CameraErrorEvent>.multi((_) {});

  @override
  Stream<DeviceOrientationChangedEvent> onDeviceOrientationChanged() =>
      const Stream.empty();

  @override
  Widget buildPreview(int cameraId) =>
      const SizedBox(key: ValueKey('camera-preview'), width: 640, height: 480);

  @override
  Future<void> dispose(int cameraId) async => disposed++;

  @override
  Future<XFile> takePicture(int cameraId) async => XFile(capture.path);

  @override
  Future<void> setFlashMode(int cameraId, FlashMode mode) async => flash = mode;

  @override
  Future<void> setFocusPoint(int cameraId, Point<double>? point) async =>
      focus = point;

  @override
  Future<void> setExposurePoint(int cameraId, Point<double>? point) async =>
      exposure = point;
}

Widget _app(Widget home) => MaterialApp(
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  locale: const Locale('en'),
  home: home,
);

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump(const Duration(milliseconds: 50));
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

void main() {
  late Directory directory;
  late File capture;
  late Uint8List original;
  late CameraPlatform previousPlatform;

  setUp(() async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    directory = await Directory.systemTemp.createTemp('paperless_camera_test_');
    final image = img.Image(width: 100, height: 141);
    img.fill(image, color: img.ColorRgb8(230, 230, 230));
    original = Uint8List.fromList(img.encodeJpg(image));
    capture = await File(
      '${directory.path}/capture.jpg',
    ).writeAsBytes(original);
    previousPlatform = CameraPlatform.instance;
  });

  tearDown(() async {
    debugDefaultTargetPlatformOverride = null;
    CameraPlatform.instance = previousPlatform;
    await directory.delete(recursive: true);
  });

  testWidgets('camera releases on background and resumes without microphone', (
    tester,
  ) async {
    final camera = _Camera(capture);
    CameraPlatform.instance = camera;
    await tester.pumpWidget(
      _app(
        ScanCapturePage(
          initialPageCount: 0,
          initialFormat: ScanPageFormat.auto,
          onSave: (_, _) async {},
        ),
      ),
    );
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    expect(camera.audioEnabled, isFalse);
    await tester.tap(find.byTooltip('Toggle camera light'));
    await tester.pump();
    expect(camera.flash, FlashMode.torch);
    await tester.tapAt(
      tester.getCenter(find.byKey(const ValueKey('camera-preview'))),
    );
    await tester.pump();
    expect(camera.focus, isNotNull);
    expect(camera.exposure, camera.focus);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    expect(camera.disposed, 1);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    expect(camera.created, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(camera.disposed, 2);
  });

  testWidgets('capture, review and save returns to the multi-page camera', (
    tester,
  ) async {
    final camera = _Camera(capture);
    CameraPlatform.instance = camera;
    ScanEditorResult? saved;
    await tester.pumpWidget(
      _app(
        ScanCapturePage(
          initialPageCount: 2,
          initialFormat: ScanPageFormat.auto,
          onSave: (source, result) async {
            expect(source, original);
            saved = result;
          },
        ),
      ),
    );
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    await tester.tap(find.byIcon(Icons.camera_alt));
    await _waitFor(tester, find.text('Done (3)'));
    expect(await tester.runAsync(capture.exists), isFalse);
    expect(camera.disposed, 0);
    await tester.tap(find.byType(Image).first);
    await _waitFor(tester, find.byType(ChoiceChip));
    await tester.tap(find.text('Rotate'));
    await _waitFor(tester, find.text('Crop'));
    await tester.tap(find.text('Save'));
    await tester.tap(find.text('Done (3)'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 300)),
    );
    await tester.pump();
    expect(saved, isNotNull);
    expect(saved!.edit.quarterTurns, 1);
    final output = img.decodeJpg(saved!.rendered)!;
    expect(output.width, greaterThan(output.height));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });

  testWidgets(
    'denied camera access leaves image import and settings available',
    (tester) async {
      CameraPlatform.instance = _Camera(capture, denied: true);
      await tester.pumpWidget(
        _app(
          ScanCapturePage(
            initialPageCount: 0,
            initialFormat: ScanPageFormat.auto,
            onSave: (_, _) async {},
          ),
        ),
      );
      await _waitFor(tester, find.text('Settings'));
      expect(find.byTooltip('Import a page image'), findsOneWidget);
      expect(find.text('Retry camera or image'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    },
  );

  testWidgets('failed persistence keeps the editor open for retry', (
    tester,
  ) async {
    var attempts = 0;
    await tester.pumpWidget(
      _app(
        ScanEditorPage(
          original: original,
          initialEdit: ScanEdit(corners: ScanEdit.fullPage),
          onSave: (_) async {
            attempts++;
            throw const FileSystemException('Storage full');
          },
        ),
      ),
    );
    await _waitFor(tester, find.byType(ChoiceChip));
    await tester.tap(find.text('Save'));
    await _waitFor(tester, find.textContaining('Storage full'));
    expect(attempts, 1);
    expect(find.byType(ScanEditorPage), findsOneWidget);
    await tester.tap(find.text('Save'));
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 200)),
    );
    await tester.pump();
    expect(attempts, 2);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
