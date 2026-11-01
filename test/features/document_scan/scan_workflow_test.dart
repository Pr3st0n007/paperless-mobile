import 'dart:io';
import 'dart:math';

import 'package:camera_platform_interface/camera_platform_interface.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:logger/logger.dart';
import 'package:paperless_mobile/core/service/connectivity_status_service.dart';
import 'package:paperless_mobile/features/document_scan/cubit/document_scanner_cubit.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/camera_permission_gateway.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/scan_camera_session.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_capture_page.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/capture_controls.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/features/document_scan/view/scanner_page.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_repository.dart';
import 'package:paperless_mobile/features/document_scan/view/widgets/export_scans_dialog.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';
import 'package:paperless_mobile/features/notifications/services/local_notification_service.dart';
import 'package:paperless_mobile/features/settings/model/color_scheme_option.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/theme.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _Permissions implements CameraPermissionGateway {
  CameraPermissionStatus current;
  int requests = 0;

  _Permissions(this.current);

  @override
  Future<CameraPermissionStatus> status() async => current;

  @override
  Future<CameraPermissionStatus> request() async {
    requests++;
    return current;
  }

  @override
  Future<void> openSettings() async {}
}

class _Notifications extends Fake implements LocalNotificationService {}

class _Connectivity extends Fake implements ConnectivityStatusService {
  @override
  Stream<bool> connectivityChanges() => Stream.value(false);
}

class _Camera extends CameraPlatform {
  final File capture;
  final bool denied;
  int created = 0;
  int disposed = 0;
  int _open = 0;
  bool overlapped = false;
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
    if (_open > 0) overlapped = true;
    _open++;
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
  Future<void> dispose(int cameraId) async {
    await Future<void>.delayed(const Duration(milliseconds: 5));
    _open--;
    disposed++;
  }

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

Widget _app(
  Widget home, {
  Locale locale = const Locale('en'),
  double textScale = 1,
  ThemeData? theme,
}) => MaterialApp(
  localizationsDelegates: S.localizationsDelegates,
  supportedLocales: S.supportedLocales,
  locale: locale,
  theme: theme,
  builder: (context, child) => MediaQuery(
    data: MediaQuery.of(
      context,
    ).copyWith(textScaler: TextScaler.linear(textScale)),
    child: child!,
  ),
  home: home,
);

Future<void> _waitFor(WidgetTester tester, Finder finder) async {
  for (var i = 0; i < 100; i++) {
    await _settle(tester);
    if (finder.evaluate().isNotEmpty) return;
  }
  expect(finder, findsWidgets);
}

Future<void> _settle(WidgetTester tester) async {
  await tester.runAsync(
    () => Future<void>.delayed(const Duration(milliseconds: 20)),
  );
  await tester.pump(const Duration(milliseconds: 50));
}

Future<void> _waitUntil(WidgetTester tester, bool Function() condition) async {
  for (var i = 0; i < 100 && !condition(); i++) {
    await _settle(tester);
  }
  expect(condition(), isTrue);
}

bool _enabled(WidgetTester tester, String label) =>
    tester
        .widget<ButtonStyleButton>(
          find.ancestor(
            of: find.text(label),
            matching: find.byWidgetPredicate((w) => w is ButtonStyleButton),
          ),
        )
        .onPressed !=
    null;

final _android = TargetPlatformVariant.only(TargetPlatform.android);

void main() {
  late Directory directory;
  late File capture;
  late Uint8List original;
  late CameraPlatform previousPlatform;

  setUp(() async {
    logger = Logger(level: Level.off);
    ScanCameraSession.resetPlatformQueue();
    SharedPreferences.setMockInitialValues({'scanner.tipsSeen': true});
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
    CameraPlatform.instance = previousPlatform;
    await directory.delete(recursive: true);
  });

  testWidgets(
    'camera releases on background and resumes without microphone',
    (tester) async {
      final camera = _Camera(capture);
      CameraPlatform.instance = camera;
      await tester.pumpWidget(
        _app(
          ScanCapturePage(
            initialPageCount: 0,
            initialFormat: ScanPageFormat.auto,
            permissions: _Permissions(CameraPermissionStatus.granted),
            onSave: (_, _) async {},
          ),
        ),
      );
      await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
      expect(camera.audioEnabled, isFalse);
      await tester.tap(find.byTooltip('Toggle camera light'));
      await _settle(tester);
      expect(camera.flash, FlashMode.torch);
      await tester.tapAt(
        tester.getCenter(find.byKey(const ValueKey('camera-preview'))),
      );
      await _settle(tester);
      expect(camera.focus, isNotNull);
      expect(camera.focus!.x, closeTo(0.5, 0.01));
      expect(camera.focus!.y, closeTo(0.5, 0.01));
      expect(camera.exposure, camera.focus);
      // Permission dialogs and the notification shade only make the app
      // inactive; the camera must survive that.
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      await _settle(tester);
      expect(camera.disposed, 0);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await _settle(tester);
      expect(camera.disposed, 1);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
      expect(camera.created, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
      expect(camera.disposed, 2);
    },
    variant: _android,
  );

  testWidgets('a late dispose never overlaps a newer camera', (tester) async {
    final camera = _Camera(capture);
    CameraPlatform.instance = camera;
    Widget page() => _app(
      ScanCapturePage(
        key: UniqueKey(),
        initialPageCount: 0,
        initialFormat: ScanPageFormat.auto,
        permissions: _Permissions(CameraPermissionStatus.granted),
        onSave: (_, _) async {},
      ),
    );
    await tester.pumpWidget(page());
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    await tester.pumpWidget(page());
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    expect(camera.created, 2);
    expect(camera.disposed, 1);
    expect(camera.overlapped, isFalse);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  }, variant: _android);

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
          permissions: _Permissions(CameraPermissionStatus.granted),
          onSave: (source, result) async {
            expect(source, original);
            saved = result;
          },
        ),
      ),
    );
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    await tester.tap(find.bySemanticsLabel('Capture page'));
    await _waitFor(tester, find.text('Done (3)'));
    expect(await tester.runAsync(capture.exists), isFalse);
    expect(camera.disposed, 0);
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.bySemanticsLabel('Page 1'));
    await _waitFor(tester, find.text('Edit captured page'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('Edit captured page'));
    await _waitFor(tester, find.byType(ChoiceChip));
    await tester.tap(find.byTooltip('Rotate'));
    await _waitUntil(tester, () => _enabled(tester, 'Save'));
    await tester.tap(find.text('Save'));
    await _waitFor(tester, find.text('Done (3)'));
    await _waitUntil(tester, () => _enabled(tester, 'Done (3)'));
    await tester.tap(find.text('Done (3)'));
    await _waitUntil(tester, () => saved != null);
    expect(saved!.edit.quarterTurns, 1);
    final output = img.decodeJpg(saved!.rendered)!;
    expect(output.width, greaterThan(output.height));
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  }, variant: _android);

  testWidgets(
    'denied camera access leaves image import and settings available',
    (tester) async {
      CameraPlatform.instance = _Camera(capture, denied: true);
      await tester.pumpWidget(
        _app(
          ScanCapturePage(
            initialPageCount: 0,
            initialFormat: ScanPageFormat.auto,
            permissions: _Permissions(CameraPermissionStatus.granted),
            onSave: (_, _) async {},
          ),
        ),
      );
      await _waitFor(tester, find.text('Settings'));
      expect(find.byTooltip('Import a page image'), findsOneWidget);
      expect(find.text('Camera access needed'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    },
    variant: _android,
  );

  testWidgets('denied permission explains and offers a retry', (tester) async {
    final camera = _Camera(capture);
    CameraPlatform.instance = camera;
    final permissions = _Permissions(CameraPermissionStatus.denied);
    await tester.pumpWidget(
      _app(
        ScanCapturePage(
          initialPageCount: 0,
          initialFormat: ScanPageFormat.auto,
          permissions: permissions,
          onSave: (_, _) async {},
        ),
      ),
    );
    await _waitFor(tester, find.text('Allow camera access'));
    expect(permissions.requests, 1);
    expect(camera.created, 0);
    permissions.current = CameraPermissionStatus.granted;
    await tester.tap(find.text('Allow camera access'));
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    expect(camera.created, 1);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  }, variant: _android);

  testWidgets('leaving with unsaved pages asks before discarding', (
    tester,
  ) async {
    final camera = _Camera(capture);
    CameraPlatform.instance = camera;
    var saves = 0;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute(
                builder: (_) => ScanCapturePage(
                  initialPageCount: 0,
                  initialFormat: ScanPageFormat.auto,
                  permissions: _Permissions(CameraPermissionStatus.granted),
                  onSave: (_, _) async => saves++,
                ),
              ),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
    await tester.tap(find.bySemanticsLabel('Capture page'));
    await _waitFor(tester, find.text('Done (1)'));
    await tester.pageBack();
    await _waitFor(tester, find.text('Discard captured pages?'));
    await tester.tap(find.text('Keep scanning'));
    await _settle(tester);
    expect(find.byType(ScanCapturePage), findsOneWidget);
    await tester.pageBack();
    await _waitFor(tester, find.text('Save pages'));
    await tester.tap(find.text('Save pages'));
    await _waitUntil(
      tester,
      () => find.byType(ScanCapturePage).evaluate().isEmpty,
    );
    expect(saves, 1);
    await _settle(tester);
  }, variant: _android);

  for (final configuration in [
    (size: const Size(320, 568), scale: 1.0, language: 'en', dark: false),
    (size: const Size(384, 720), scale: 1.0, language: 'de', dark: true),
    (size: const Size(320, 568), scale: 2.0, language: 'de', dark: true),
    (size: const Size(844, 390), scale: 1.3, language: 'de', dark: false),
    (size: const Size(1024, 768), scale: 2.0, language: 'en', dark: false),
  ]) {
    testWidgets('editor fits $configuration', (tester) async {
      await tester.binding.setSurfaceSize(configuration.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(
        _app(
          ScanEditorPage(original: original, scanFormat: ScanPageFormat.a4),
          locale: Locale(configuration.language),
          textScale: configuration.scale,
          theme: buildTheme(
            brightness: configuration.dark ? Brightness.dark : Brightness.light,
            preferredColorScheme: ColorSchemeOption.classic,
          ),
        ),
      );
      await _waitFor(tester, find.byType(ChoiceChip));
      expect(find.byType(ChoiceChip), findsNWidgets(ScanFilter.values.length));
      final previewSize = tester.getSize(find.byType(Image));
      expect(previewSize.height, greaterThan(120));
      expect(previewSize.width, greaterThan(100));
      final s = S.of(tester.element(find.byType(ScanEditorPage)))!;
      await tester.ensureVisible(
        find.byType(DropdownButton<ScanPageFormatKind>),
      );
      await tester.pumpAndSettle();
      final labelSize = tester.getSize(find.text(s.scannerOutputFormat));
      expect(labelSize.width, greaterThan(200));
      await tester.tap(find.byType(DropdownButton<ScanPageFormatKind>));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.scannerFormatLetter).last);
      await tester.pumpAndSettle();
      expect(find.text(s.scannerFormatOverride), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    }, variant: _android);
  }

  testWidgets('editor previews, zooms, crops and saves selected settings', (
    tester,
  ) async {
    ScanEditorResult? saved;
    await tester.pumpWidget(
      _app(
        ScanEditorPage(
          original: original,
          onSave: (result) async => saved = result,
        ),
      ),
    );
    await _waitFor(tester, find.byType(ChoiceChip));
    await tester.tap(find.byType(DropdownButton<ScanPageFormatKind>));
    await tester.pumpAndSettle();
    await tester.tap(find.text('A4').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Grayscale'));
    await tester.tap(find.text('Preview'));
    await _waitFor(tester, find.byType(InteractiveViewer));
    expect(
      tester.widget<InteractiveViewer>(find.byType(InteractiveViewer)).maxScale,
      5,
    );
    await tester.tap(find.text('Crop'));
    await tester.pump();
    expect(find.byType(InteractiveViewer), findsNothing);
    await tester.tap(find.byTooltip('Rotate'));
    await _waitFor(tester, find.byType(InteractiveViewer));
    await tester.tap(find.text('Save'));
    await _waitUntil(tester, () => saved != null);
    expect(saved!.edit.filter, ScanFilter.grayscale);
    expect(saved!.edit.quarterTurns, 1);
    expect(saved!.edit.pageFormat, ScanPageFormat.a4);
    expect(saved!.edit.formatOverride, isTrue);
    expect(saved!.rendered, isNotEmpty);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  }, variant: _android);

  for (final configuration in [
    (size: const Size(320, 568), scale: 2.0),
    (size: const Size(844, 390), scale: 1.3),
    (size: const Size(1024, 768), scale: 2.0),
  ]) {
    testWidgets('capture and collection fit $configuration', (tester) async {
      await tester.binding.setSurfaceSize(configuration.size);
      addTearDown(() => tester.binding.setSurfaceSize(null));
      CameraPlatform.instance = _Camera(capture);
      await tester.pumpWidget(
        _app(
          ScanCapturePage(
            initialPageCount: 0,
            initialFormat: ScanPageFormat.auto,
            permissions: _Permissions(CameraPermissionStatus.granted),
            onSave: (_, _) async {},
          ),
          locale: const Locale('de'),
          textScale: configuration.scale,
        ),
      );
      await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
      final s = S.of(tester.element(find.byType(ScanCapturePage)))!;
      expect(_enabled(tester, '${s.done} (0)'), isFalse);
      await tester.tap(find.bySemanticsLabel(s.scannerShutter));
      await _waitFor(tester, find.text('${s.done} (1)'));
      expect(tester.takeException(), isNull);
      expect(
        tester.getSize(find.byKey(const ValueKey('camera-preview'))).height,
        greaterThan(120),
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);

      final repository = ScanRepository(
        Directory('${directory.path}/collection'),
      );
      final cubit = DocumentScannerCubit(
        _Notifications(),
        repository: repository,
      );
      await tester.runAsync(
        () => cubit.saveScan(
          original: original,
          rendered: original,
          edit: ScanEdit(corners: ScanEdit.fullPage),
        ),
      );
      await tester.pumpWidget(
        _app(
          RepositoryProvider<ConnectivityStatusService>.value(
            value: _Connectivity(),
            child: BlocProvider.value(value: cubit, child: const ScannerPage()),
          ),
          locale: const Locale('de'),
          textScale: configuration.scale,
        ),
      );
      await _settle(tester);
      expect(find.text(s.export), findsOneWidget);
      expect(find.text(s.upload), findsOneWidget);
      expect(_enabled(tester, s.upload), isFalse);
      expect(tester.takeException(), isNull);
      await tester.tap(find.byTooltip(s.clearAll));
      await tester.pumpAndSettle();
      expect(find.text(s.confirmDeletion), findsOneWidget);
      await tester.tap(find.text(s.cancel));
      await tester.pumpAndSettle();
      expect(cubit.state.scans, hasLength(1));
      await tester.tap(find.byTooltip(s.clearAll));
      await tester.pumpAndSettle();
      await tester.tap(find.text(s.delete));
      await _waitUntil(tester, () => cubit.state.scans.isEmpty);
      await _settle(tester);
      expect(find.text(s.noDocumentsScannedYet), findsOneWidget);
      expect(tester.takeException(), isNull);
      await tester.pumpWidget(const SizedBox.shrink());
      await cubit.close();
      await _settle(tester);
    }, variant: _android);
  }

  testWidgets(
    'retake reviews one replacement then returns to the collection',
    (tester) async {
      var saves = 0;
      CameraPlatform.instance = _Camera(capture);
      await tester.pumpWidget(
        _app(
          Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () => Navigator.push(
                  context,
                  MaterialPageRoute<void>(
                    builder: (_) => ScanCapturePage(
                      initialPageCount: 2,
                      initialFormat: ScanPageFormat.letter,
                      initialFormatOverride: true,
                      retake: true,
                      permissions: _Permissions(CameraPermissionStatus.granted),
                      onSave: (_, result) async {
                        saves++;
                        expect(result.edit.pageFormat, ScanPageFormat.letter);
                        expect(result.edit.formatOverride, isTrue);
                      },
                    ),
                  ),
                ),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await _waitFor(tester, find.byKey(const ValueKey('camera-preview')));
      await tester.tap(find.byType(ShutterButton));
      await _waitFor(tester, find.byType(ChoiceChip));
      expect(saves, 0);
      await tester.tap(find.text('Save'));
      await _waitFor(tester, find.text('open'));
      await _waitUntil(
        tester,
        () => find.byType(ScanCapturePage).evaluate().isEmpty,
      );
      expect(saves, 1);
      expect(find.byType(ScanCapturePage), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await _settle(tester);
    },
    variant: _android,
  );

  testWidgets('export validates names and submits once from the keyboard', (
    tester,
  ) async {
    String? exported;
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () async => exported = await showDialog<String>(
                context: context,
                builder: (_) => const ExportScansDialog(),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    final field = find.byType(TextFormField);
    expect(
      tester.widget<TextFormField>(field).controller!.text,
      startsWith('Scan_'),
    );
    await tester.enterText(field, r'bad\name');
    await tester.tap(find.text('Export'));
    await tester.pumpAndSettle();
    expect(exported, isNull);
    expect(find.byType(ExportScansDialog), findsOneWidget);
    await tester.enterText(field, 'Invoice.PDF');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await tester.pumpAndSettle();
    expect(exported, 'Invoice');
    expect(find.byType(ExportScansDialog), findsNothing);
  });

  testWidgets('editor asks before abandoning changed pages', (tester) async {
    await tester.pumpWidget(
      _app(
        Builder(
          builder: (context) => Scaffold(
            body: TextButton(
              onPressed: () => Navigator.push(
                context,
                MaterialPageRoute<void>(
                  builder: (_) => ScanEditorPage(original: original),
                ),
              ),
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await _waitFor(tester, find.byType(ChoiceChip));
    await tester.tap(find.text('Grayscale'));
    await tester.pump();
    await tester.pageBack();
    await tester.pumpAndSettle();
    expect(find.text('Discard changes?'), findsOneWidget);
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanEditorPage), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    await tester.tap(find.text('Discard'));
    await tester.pumpAndSettle();
    expect(find.byType(ScanEditorPage), findsNothing);
  }, variant: _android);

  testWidgets('reset preserves the selected paper size', (tester) async {
    ScanEditorResult? saved;
    await tester.pumpWidget(
      _app(
        ScanEditorPage(
          original: original,
          initialEdit: ScanEdit(
            corners: ScanEdit.fullPage,
            pageFormat: ScanPageFormat.letter,
            formatOverride: true,
            filter: ScanFilter.grayscale,
            quarterTurns: 1,
          ),
          onSave: (result) async => saved = result,
        ),
      ),
    );
    await _waitFor(tester, find.byTooltip('Reset'));
    await tester.tap(find.byTooltip('Reset'));
    await tester.tap(find.text('Save'));
    await _waitUntil(tester, () => saved != null);
    expect(saved!.edit.pageFormat, ScanPageFormat.letter);
    expect(saved!.edit.formatOverride, isTrue);
    expect(saved!.edit.quarterTurns, 0);
    expect(saved!.edit.filter, ScanFilter.document);
    await tester.pumpWidget(const SizedBox.shrink());
    await _settle(tester);
  }, variant: _android);

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
