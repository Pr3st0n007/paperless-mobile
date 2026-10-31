import 'dart:async';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_preview_transform.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';

class ScanCapturePage extends StatefulWidget {
  final Future<void> Function(Uint8List original, ScanEditorResult result)
  onSave;
  final int initialPageCount;
  final ScanPageFormat initialFormat;
  final bool initialFormatOverride;

  const ScanCapturePage({
    super.key,
    required this.onSave,
    required this.initialPageCount,
    required this.initialFormat,
    this.initialFormatOverride = false,
  });

  @override
  State<ScanCapturePage> createState() => _ScanCapturePageState();
}

class _CapturedPage {
  final File originalFile;
  ScanEdit edit;
  Uint8List preview;
  bool persisted = false;

  _CapturedPage(this.originalFile, this.edit, this.preview);
}

class _ScanCapturePageState extends State<ScanCapturePage>
    with WidgetsBindingObserver {
  CameraController? _camera;
  bool _initializing = true;
  bool _busy = false;
  bool _foreground = true;
  bool _torch = false;
  bool _haptics = true;
  bool _autoCapture = false;
  bool _analyzingFrame = false;
  bool _streamUnavailable = false;
  int _generation = 0;
  int _frameGeneration = 0;
  int? _retakeIndex;
  Size? _frameSize;
  List<Point<double>>? _corners;
  ScanQualityAssessment? _quality;
  Uint8List? _lastFingerprint;
  ScanBoundaryStatus _boundaryStatus = ScanBoundaryStatus.uncertain;
  final _stability = ScanBoundaryStability();
  final _autoGate = ScanAutoCaptureGate();
  final List<_CapturedPage> _capturedPages = [];
  Future<Directory>? _draftDirectory;
  int _savedCount = 0;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  int get _pageCount =>
      widget.initialPageCount + _capturedPages.length + _savedCount;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _initializeCamera();
  }

  Future<void> _releaseCamera() async {
    _generation++;
    _frameGeneration++;
    final controller = _camera;
    _camera = null;
    _torch = false;
    _stability.update(null);
    _corners = null;
    _quality = null;
    _boundaryStatus = ScanBoundaryStatus.uncertain;
    if (mounted) setState(() {});
    await controller?.dispose();
  }

  Future<Directory> _getDraftDirectory() =>
      _draftDirectory ??= Directory.systemTemp.createTemp(
        'paperless_scan_draft_',
      );

  Future<void> _cleanupDrafts() async {
    final pending = _draftDirectory;
    if (pending == null) return;
    final directory = await pending;
    if (await directory.exists()) await directory.delete(recursive: true);
    _draftDirectory = null;
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
        imageFormatGroup: _isAndroid
            ? ImageFormatGroup.yuv420
            : ImageFormatGroup.unknown,
      );
      await controller.initialize();
      if (!mounted || generation != _generation) {
        await controller.dispose();
        return;
      }
      setState(() => _camera = controller);
      await _startImageStream(controller);
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

  Future<void> _startImageStream(CameraController camera) async {
    if (!_isAndroid ||
        !camera.value.isInitialized ||
        camera.value.isStreamingImages ||
        !_foreground) {
      return;
    }
    try {
      await camera.startImageStream(_processFrame);
      if (mounted && camera == _camera && _streamUnavailable) {
        setState(() => _streamUnavailable = false);
      }
    } catch (error, stackTrace) {
      if (!mounted || camera != _camera) return;
      setState(() {
        _streamUnavailable = true;
        _corners = null;
        _boundaryStatus = ScanBoundaryStatus.uncertain;
      });
      showGenericError(context, error, stackTrace);
    }
  }

  Future<void> _stopImageStream(CameraController? camera) async {
    if (camera == null || !camera.value.isStreamingImages) return;
    await camera.stopImageStream();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _foreground = true;
      if (_camera == null && !_busy) {
        _initializeCamera();
      } else if (_camera != null) {
        _startImageStream(_camera!);
      }
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
    unawaited(
      _cleanupDrafts().catchError((Object error, StackTrace stackTrace) {
        if (mounted) showGenericError(context, error, stackTrace);
      }),
    );
    super.dispose();
  }

  int _deviceOrientationDegrees(DeviceOrientation orientation) => switch (
    orientation
  ) {
    DeviceOrientation.portraitUp => 0,
    DeviceOrientation.landscapeLeft => 90,
    DeviceOrientation.portraitDown => 180,
    DeviceOrientation.landscapeRight => 270,
  };

  int _rotationFor(CameraController camera) {
    final sensor = camera.description.sensorOrientation;
    final device = _deviceOrientationDegrees(camera.value.deviceOrientation);
    return (sensor - device + 360) % 360;
  }

  Map<String, Object> _rgbFrame(CameraImage frame) {
    final scale = min(1.0, 320 / max(frame.width, frame.height));
    final width = max(1, (frame.width * scale).round());
    final height = max(1, (frame.height * scale).round());
    final rgb = Uint8List(width * height * 3);
    final format = frame.format.group;
    final planes = frame.planes;
    if (format == ImageFormatGroup.yuv420 && planes.length >= 3) {
      final yPlane = planes[0];
      final uPlane = planes[1];
      final vPlane = planes[2];
      final uPixelStride = uPlane.bytesPerPixel ?? 1;
      final vPixelStride = vPlane.bytesPerPixel ?? 1;
      for (var y = 0; y < height; y++) {
        final sourceY = min(frame.height - 1, (y / scale).floor());
        for (var x = 0; x < width; x++) {
          final sourceX = min(frame.width - 1, (x / scale).floor());
          final luminance = yPlane.bytes[
            sourceY * yPlane.bytesPerRow + sourceX
          ];
          final uIndex =
              (sourceY ~/ 2) * uPlane.bytesPerRow +
              (sourceX ~/ 2) * uPixelStride;
          final vIndex =
              (sourceY ~/ 2) * vPlane.bytesPerRow +
              (sourceX ~/ 2) * vPixelStride;
          final chromaU = uPlane.bytes[uIndex] - 128;
          final chromaV = vPlane.bytes[vIndex] - 128;
          final c = max(0, luminance - 16);
          final offset = (y * width + x) * 3;
          rgb[offset] = (((298 * c + 409 * chromaV + 128) >> 8)
                  .clamp(0, 255))
              .toInt();
          rgb[offset + 1] =
              (((298 * c - 100 * chromaU - 208 * chromaV + 128) >> 8)
                      .clamp(0, 255))
                  .toInt();
          rgb[offset + 2] = (((298 * c + 516 * chromaU + 128) >> 8)
                  .clamp(0, 255))
              .toInt();
        }
      }
    } else if (format == ImageFormatGroup.bgra8888 && planes.isNotEmpty) {
      final plane = planes.first;
      for (var y = 0; y < height; y++) {
        final sourceY = min(frame.height - 1, (y / scale).floor());
        for (var x = 0; x < width; x++) {
          final sourceX = min(frame.width - 1, (x / scale).floor());
          final input = sourceY * plane.bytesPerRow + sourceX * 4;
          final output = (y * width + x) * 3;
          rgb[output] = plane.bytes[input + 2];
          rgb[output + 1] = plane.bytes[input + 1];
          rgb[output + 2] = plane.bytes[input];
        }
      }
    } else {
      throw FormatException('Unsupported camera format: $format');
    }
    return {'width': width, 'height': height, 'rgb': rgb};
  }

  List<Point<double>>? _rotateCorners(
    List<Point<double>>? corners,
    int rotation,
  ) => corners == null
      ? null
      : ScanPreviewTransform.rotateCorners(corners, rotation);

  Future<void> _processFrame(CameraImage frame) async {
    final camera = _camera;
    if (_analyzingFrame || _busy || camera == null || !_foreground) return;
    _analyzingFrame = true;
    final generation = _generation;
    final frameGeneration = _frameGeneration;
    try {
      final input = _rgbFrame(frame);
      final rotation = _rotationFor(camera);
      final analysis = await compute(DocumentProcessor.analyzeRgbFrame, input);
      if (!mounted ||
          generation != _generation ||
          frameGeneration != _frameGeneration ||
          camera != _camera) {
        return;
      }
      final corners = _rotateCorners(analysis.detectedCorners, rotation);
      final update = _stability.update(corners);
      _frameSize = Size(
        rotation == 90 || rotation == 270 ? frame.height.toDouble() : frame.width.toDouble(),
        rotation == 90 || rotation == 270 ? frame.width.toDouble() : frame.height.toDouble(),
      );
      _corners = update.corners;
      _boundaryStatus = update.status;
      _quality = analysis.quality;
      _lastFingerprint = analysis.pageFingerprint;
      _autoGate.observe(
        corners: corners,
        fingerprint: analysis.pageFingerprint,
      );
      if (update.transitionedToStable) {
        SemanticsService.announce(
          S.of(context)!.scannerLiveStable,
          Directionality.of(context),
        );
        if (_haptics) HapticFeedback.selectionClick();
      }
      setState(() {});
      if (_autoGate.shouldCapture(
        stable: update.status == ScanBoundaryStatus.stable,
        qualityAcceptable: analysis.quality.isAcceptable,
        retaking: _retakeIndex != null,
      )) {
        unawaited(_acquire());
      }
    } on FormatException {
      if (mounted && !_streamUnavailable) {
        _stability.update(null);
        setState(() {
          _streamUnavailable = true;
          _corners = null;
          _quality = null;
          _boundaryStatus = ScanBoundaryStatus.uncertain;
        });
      }
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      _analyzingFrame = false;
    }
  }

  Future<void> _acquire({bool import = false}) async {
    if (_busy) return;
    final camera = _camera;
    if (!import && (camera == null || !camera.value.isInitialized)) return;
    _frameGeneration++;
    setState(() => _busy = true);
    try {
      await _stopImageStream(camera);
      Uint8List? bytes;
      if (import) {
        if (!_isAndroid) await _releaseCamera();
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
        final capture = await camera!.takePicture();
        try {
          bytes = await capture.readAsBytes();
        } finally {
          final file = File(capture.path);
          if (await file.exists()) await file.delete();
        }
        if (!_isAndroid) await _releaseCamera();
      }
      if (!mounted || bytes == null) return;
      final original = Uint8List.fromList(bytes);
      final analysis = await compute(DocumentProcessor.analyze, original);
      final edit = ScanEdit(
        corners: analysis.detectedCorners ?? ScanEdit.fullPage,
        pageFormat: widget.initialFormat,
        formatOverride: widget.initialFormatOverride,
      );
      if (!_isAndroid) {
        final result = await Navigator.of(context).push<ScanEditorResult>(
          MaterialPageRoute(
            builder: (_) => ScanEditorPage(
              original: original,
              initialEdit: edit,
              scanFormat: ScanPageFormat.a4,
              onSave: (result) => widget.onSave(original, result),
            ),
          ),
        );
        if (mounted && result != null) setState(() => _savedCount++);
        return;
      }
      final preview = await compute(
        DocumentProcessor.render,
        ScanRenderRequest(original, edit, preview: true),
      );
      final directory = await _getDraftDirectory();
      final originalFile = File(
        '${directory.path}/page_${DateTime.now().microsecondsSinceEpoch}.jpg',
      );
      await originalFile.writeAsBytes(original, flush: true);
      final page = _CapturedPage(originalFile, edit, preview);
      final replaceIndex = _retakeIndex;
      final oldFile = replaceIndex != null &&
              replaceIndex >= 0 &&
              replaceIndex < _capturedPages.length
          ? _capturedPages[replaceIndex].originalFile
          : null;
      setState(() {
        if (replaceIndex != null &&
            replaceIndex >= 0 &&
            replaceIndex < _capturedPages.length) {
          _capturedPages[replaceIndex] = page;
        } else {
          _capturedPages.add(page);
        }
        _retakeIndex = null;
        _autoGate.pageCaptured(
          corners: _corners,
          fingerprint: _lastFingerprint,
        );
      });
      if (oldFile != null) await oldFile.delete();
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_foreground && camera != null && camera == _camera) {
          await _startImageStream(camera);
        } else if (_camera == null && _foreground) {
          await _initializeCamera();
        }
      }
    }
  }

  Future<void> _openEditor(int index) async {
    if (_busy || index < 0 || index >= _capturedPages.length) return;
    final camera = _camera;
    _frameGeneration++;
    setState(() => _busy = true);
    try {
      await _stopImageStream(camera);
      final page = _capturedPages[index];
      final original = await page.originalFile.readAsBytes();
      final result = await Navigator.of(context).push<ScanEditorResult>(
        MaterialPageRoute(
          builder: (_) => ScanEditorPage(
            original: original,
            initialEdit: page.edit,
            scanFormat: widget.initialFormat,
          ),
        ),
      );
      if (mounted && result != null) {
        final preview = await compute(
          DocumentProcessor.render,
          ScanRenderRequest(original, result.edit, preview: true),
        );
        if (!mounted) return;
        setState(() {
          _capturedPages[index]
            ..edit = result.edit
            ..preview = preview;
        });
      }
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) {
        setState(() => _busy = false);
        if (_foreground && camera != null && camera == _camera) {
          await _startImageStream(camera);
        }
      }
    }
  }

  Future<void> _deleteCapturedPage(int index) async {
    if (index < 0 || index >= _capturedPages.length) return;
    final page = _capturedPages.removeAt(index);
    if (_retakeIndex == index) {
      _retakeIndex = null;
    } else if (_retakeIndex != null && _retakeIndex! > index) {
      _retakeIndex = _retakeIndex! - 1;
    }
    if (mounted) setState(() {});
    try {
      await page.originalFile.delete();
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    }
  }

  Future<void> _finish() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      for (final page in _capturedPages) {
        if (page.persisted) continue;
        final original = await page.originalFile.readAsBytes();
        final rendered = await compute(
          DocumentProcessor.render,
          ScanRenderRequest(original, page.edit),
        );
        await widget.onSave(
          original,
          ScanEditorResult(page.edit, rendered),
        );
        page.persisted = true;
      }
      await _cleanupDrafts();
      if (mounted) Navigator.pop(context);
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
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

  Widget _buildThumbnails(S s) {
    if (_capturedPages.isEmpty) return const SizedBox.shrink();
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(s.scannerCapturedPages),
        SizedBox(
          height: 94,
          child: ListView.separated(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            scrollDirection: Axis.horizontal,
            itemCount: _capturedPages.length,
            separatorBuilder: (_, _) => const SizedBox(width: 8),
            itemBuilder: (context, index) {
                final page = _capturedPages[index];
                return SizedBox(
                  width: 68,
                  child: Column(
                    children: [
                      Expanded(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            GestureDetector(
                              onTap: () => _openEditor(index),
                              child: Image.memory(
                                page.preview,
                                fit: BoxFit.cover,
                                gaplessPlayback: true,
                              ),
                            ),
                            Positioned(
                              right: 0,
                              top: 0,
                              child: PopupMenuButton<String>(
                                padding: EdgeInsets.zero,
                                iconSize: 18,
                                tooltip: s.scannerEditCaptured,
                                onSelected: (action) {
                                  switch (action) {
                                    case 'edit':
                                      _openEditor(index);
                                      break;
                                    case 'retake':
                                      setState(() => _retakeIndex = index);
                                      break;
                                    case 'delete':
                                      unawaited(_deleteCapturedPage(index));
                                      break;
                                  }
                                },
                                itemBuilder: (_) => [
                                  PopupMenuItem(
                                    value: 'edit',
                                    child: Text(s.scannerEditCaptured),
                                  ),
                                  PopupMenuItem(
                                    value: 'retake',
                                    child: Text(s.scannerRetakeCaptured),
                                  ),
                                  PopupMenuItem(
                                    value: 'delete',
                                    child: Text(s.scannerDeleteCaptured),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                      Text(
                        '${index + 1}',
                        style: Theme.of(context).textTheme.labelSmall,
                      ),
                    ],
                  ),
                );
              },
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final camera = _camera;
    final stable = _boundaryStatus == ScanBoundaryStatus.stable;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.scanADocument),
          actions: [
            if (_isAndroid)
              IconButton(
                tooltip: s.scannerHaptics,
                onPressed: _busy
                    ? null
                    : () => setState(() => _haptics = !_haptics),
                icon: Icon(
                  _haptics ? Icons.vibration : Icons.vibration_outlined,
                ),
              ),
            IconButton(
              tooltip: s.scannerTorch,
              onPressed: _busy || camera == null ? null : _toggleTorch,
              icon: Icon(_torch ? Icons.flash_on : Icons.flash_off),
            ),
            TextButton(
              onPressed: _busy ? null : _finish,
              child: Text('${s.done} ($_pageCount)'),
            ),
          ],
        ),
        body: Column(
          children: [
            Padding(
              padding: const EdgeInsets.all(8),
              child: Column(
                children: [
                  Text(
                    _isAndroid ? s.scannerCaptureHint : s.scannerCaptureHintIos,
                    textAlign: TextAlign.center,
                  ),
                  if (_isAndroid) ...[
                    Text(
                      s.scannerQualityHint,
                      textAlign: TextAlign.center,
                      style: Theme.of(context).textTheme.bodySmall,
                    ),
                  ],
                ],
              ),
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
                                painter: _isAndroid
                                    ? _BoundaryPainter(
                                        _corners,
                                        stable,
                                        _frameSize,
                                      )
                                    : const _A4GuidePainter(),
                              ),
                            ),
                          ),
                        ),
                ),
              ),
            ),
            if (_isAndroid)
              Semantics(
                liveRegion: true,
                label: stable ? s.scannerLiveStable : s.scannerLiveUncertain,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        stable ? Icons.check_circle : Icons.circle_outlined,
                        color: stable ? Colors.green : Colors.white70,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        _streamUnavailable
                            ? s.scannerLiveUnavailable
                            : stable
                            ? s.scannerLiveStable
                            : s.scannerLiveUncertain,
                      ),
                    ],
                  ),
                ),
              ),
            if (_isAndroid) _buildThumbnails(s),
            SafeArea(
              top: false,
              child: Padding(
                padding: const EdgeInsets.all(12),
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
                                child: Icon(
                                  _retakeIndex == null
                                      ? Icons.camera_alt
                                      : Icons.refresh,
                                  size: 32,
                                ),
                              ),
                      ),
                    ),
                    if (_isAndroid)
                      Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Text(s.scannerAutoCapture),
                          Switch(
                            value: _autoCapture,
                            onChanged: _busy
                                ? null
                                : (value) {
                                    setState(() {
                                      _autoCapture = value;
                                      _autoGate.setEnabled(value);
                                    });
                                    if (_autoGate.shouldCapture(
                                      stable: stable,
                                      qualityAcceptable:
                                          _quality?.isAcceptable ?? false,
                                      retaking: _retakeIndex != null,
                                    )) {
                                      unawaited(_acquire());
                                    }
                                  },
                          ),
                        ],
                      ),
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

class _BoundaryPainter extends CustomPainter {
  final List<Point<double>>? corners;
  final bool stable;
  final Size? frameSize;

  const _BoundaryPainter(this.corners, this.stable, this.frameSize);

  @override
  void paint(Canvas canvas, Size size) {
    final points = corners;
    final source = frameSize;
    if (points == null || source == null) return;
    final mapped = ScanPreviewTransform.mapToViewport(
      corners: points,
      sourceWidth: source.width,
      sourceHeight: source.height,
      viewportWidth: size.width,
      viewportHeight: size.height,
    )
        .map((point) => Offset(point.x, point.y))
        .toList();
    final path = Path()..addPolygon(mapped, true);
    final color = stable ? Colors.greenAccent : Colors.white70;
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..strokeWidth = stable ? 3 : 2
        ..style = PaintingStyle.stroke,
    );
    if (!stable) return;
    for (final point in mapped) {
      canvas.drawCircle(point, 8, Paint()..color = Colors.greenAccent);
      canvas.drawCircle(point, 3, Paint()..color = Colors.black);
    }
  }

  @override
  bool shouldRepaint(_BoundaryPainter oldDelegate) =>
      oldDelegate.corners != corners ||
      oldDelegate.stable != stable ||
      oldDelegate.frameSize != frameSize;
}
