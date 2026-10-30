import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';
import 'package:permission_handler/permission_handler.dart';

class ScanCapturePage extends StatefulWidget {
  final Future<void> Function(Uint8List original, ScanEditorResult result)
  onSave;
  final int initialPageCount;

  const ScanCapturePage({
    super.key,
    required this.onSave,
    required this.initialPageCount,
  });

  @override
  State<ScanCapturePage> createState() => _ScanCapturePageState();
}

class _ScanCapturePageState extends State<ScanCapturePage>
    with WidgetsBindingObserver {
  CameraController? _camera;
  bool _initializing = true;
  bool _busy = false;
  bool _foreground = true;
  bool _torch = false;
  int _generation = 0;
  late int _pageCount = widget.initialPageCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  Future<void> _releaseCamera() async {
    _generation++;
    final controller = _camera;
    _camera = null;
    _torch = false;
    await controller?.dispose();
  }

  Future<void> _initializeCamera() async {
    if (!mounted || !_foreground || _busy) return;
    final generation = ++_generation;
    setState(() => _initializing = true);
    CameraController? controller;
    try {
      final cameras = await availableCameras();
      if (!mounted || generation != _generation) return;
      if (cameras.isEmpty) {
        throw CameraException('NoCamera', S.of(context)!.scannerNoCamera);
      }
      final rear = cameras.where(
        (camera) => camera.lensDirection == CameraLensDirection.back,
      );
      controller = CameraController(
        rear.isEmpty ? cameras.first : rear.first,
        ResolutionPreset.veryHigh,
        enableAudio: false,
      );
      await controller.initialize();
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
    } catch (error, stackTrace) {
      await controller?.dispose();
      if (mounted && generation == _generation) {
        showGenericError(context, error, stackTrace);
        if (error is CameraException &&
            error.code.startsWith('CameraAccessDenied')) {
          showSnackBar(
            context,
            S.of(context)!.scannerCameraPermission,
            type: SnackbarType.error,
            action: SnackBarActionConfig(
              label: S.of(context)!.settings,
              onPressed: openAppSettings,
            ),
          );
        }
      }
    } finally {
      if (mounted && generation == _generation) {
        setState(() => _initializing = false);
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_camera == null && !_busy) _initializeCamera();
    } else {
      _foreground = false;
      _releaseCamera();
      if (mounted) setState(() {});
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _releaseCamera();
    super.dispose();
  }

  Future<void> _acquire({bool import = false}) async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      Uint8List? bytes;
      if (import) {
        await _releaseCamera();
        final selection = await FilePicker.platform.pickFiles(
          type: FileType.custom,
          allowedExtensions: const ['jpg', 'jpeg', 'png'],
          withData: true,
        );
        if (selection != null) {
          final selected = selection.files.single;
          bytes = selected.bytes;
          if (bytes == null && selected.path != null) {
            bytes = await File(selected.path!).readAsBytes();
          }
          if (bytes == null) {
            throw const FileSystemException('Unable to read selected image.');
          }
        }
      } else {
        final camera = _camera;
        if (camera == null || !camera.value.isInitialized) return;
        final capture = await camera.takePicture();
        try {
          bytes = await capture.readAsBytes();
        } finally {
          await File(capture.path).delete();
        }
        await _releaseCamera();
      }
      if (!mounted || bytes == null) return;
      final original = bytes;
      final result = await Navigator.of(context).push<ScanEditorResult>(
        MaterialPageRoute(
          builder: (_) => ScanEditorPage(
            original: original,
            onSave: (result) => widget.onSave(original, result),
          ),
        ),
      );
      if (result != null) {
        if (mounted) setState(() => _pageCount++);
      }
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_camera == null) await _initializeCamera();
      }
    }
  }

  Future<void> _toggleTorch() async {
    final camera = _camera;
    if (camera == null) return;
    try {
      await camera.setFlashMode(_torch ? FlashMode.off : FlashMode.torch);
      if (mounted && camera == _camera) setState(() => _torch = !_torch);
    } on CameraException catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    }
  }

  Future<void> _focus(Offset point, Size size) async {
    final camera = _camera;
    if (camera == null || _busy) return;
    final normalized = Offset(
      (point.dx / size.width).clamp(0, 1),
      (point.dy / size.height).clamp(0, 1),
    );
    try {
      await camera.setFocusPoint(normalized);
      await camera.setExposurePoint(normalized);
    } on CameraException catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final camera = _camera;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.scanADocument),
          actions: [
            IconButton(
              tooltip: s.scannerTorch,
              onPressed: _busy || camera == null ? null : _toggleTorch,
              icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
            ),
            TextButton(
              onPressed: _busy ? null : () => Navigator.pop(context),
              child: Text('${s.done} ($_pageCount)'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(12),
              child: Text(s.scannerCaptureHint, textAlign: TextAlign.center),
            ),
            Expanded(
              child: ColoredBox(
                color: Colors.black,
                child: Center(
                  child: camera == null
                      ? _initializing || _busy
                            ? const CircularProgressIndicator()
                            : TextButton.icon(
                                onPressed: _initializeCamera,
                                icon: const Icon(Icons.refresh),
                                label: Text(s.scannerRetry),
                              )
                      : CameraPreview(
                          camera,
                          child: LayoutBuilder(
                            builder: (_, constraints) => GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTapDown: (details) => _focus(
                                details.localPosition,
                                constraints.biggest,
                              ),
                              child: CustomPaint(
                                painter: const _A4GuidePainter(),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    IconButton(
                      tooltip: s.scannerImportImage,
                      onPressed: _busy ? null : () => _acquire(import: true),
                      icon: const Icon(Icons.photo_library_outlined),
                    ),
                    SizedBox(
                      width: 72,
                      height: 72,
                      child: FilledButton(
                        style: FilledButton.styleFrom(
                          shape: const CircleBorder(),
                          padding: EdgeInsets.zero,
                        ),
                        onPressed: _busy || camera == null ? null : _acquire,
                        child: _busy
                            ? const CircularProgressIndicator()
                            : Semantics(
                                label: s.scan,
                                child: const Icon(Icons.camera_alt, size: 32),
                              ),
                      ),
                    ),
                    Text('A4', style: Theme.of(context).textTheme.titleMedium),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _A4GuidePainter extends CustomPainter {
  const _A4GuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final landscape = size.width > size.height;
    final ratio = landscape ? sqrt2 : 1 / sqrt2;
    var width = size.width * .86;
    var height = width / ratio;
    if (height > size.height * .86) {
      height = size.height * .86;
      width = height * ratio;
    }
    final rect = Rect.fromCenter(
      center: size.center(Offset.zero),
      width: width,
      height: height,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_A4GuidePainter oldDelegate) => false;
}
