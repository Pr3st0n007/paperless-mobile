import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/camera_permission_gateway.dart';

enum ScanCameraStatus {
  idle,
  checkingPermission,
  permissionRequired,
  permissionPermanentlyDenied,
  initializing,
  ready,
  noCamera,
  failed,
}

@immutable
class ScanCameraState {
  final ScanCameraStatus status;
  final CameraController? controller;
  final bool torchOn;

  /// False when the device cannot stream frames in a supported format; manual
  /// capture keeps working.
  final bool liveAnalysisAvailable;
  final Object? error;

  const ScanCameraState({
    this.status = ScanCameraStatus.idle,
    this.controller,
    this.torchOn = false,
    this.liveAnalysisAvailable = true,
    this.error,
  });

  bool get isReady => status == ScanCameraStatus.ready && controller != null;

  ScanCameraState copyWith({bool? torchOn, bool? liveAnalysisAvailable}) =>
      ScanCameraState(
        status: status,
        controller: controller,
        torchOn: torchOn ?? this.torchOn,
        liveAnalysisAvailable:
            liveAnalysisAvailable ?? this.liveAnalysisAvailable,
        error: error,
      );
}

/// Owns the camera controller lifecycle for the capture screen.
///
/// The Android CameraX plugin keeps one shared native session for all
/// controllers, so a late `dispose()` of an old controller unbinds the preview
/// of a newer one (black preview while analysis still runs). Every platform
/// call is therefore serialized through a process-wide queue, and stale opens
/// are cancelled through [_token] instead of racing with them.
class ScanCameraSession {
  final CameraPermissionGateway permissions;
  final ResolutionPreset resolution;
  final ImageFormatGroup streamFormat;
  final ValueNotifier<ScanCameraState> state = ValueNotifier(
    const ScanCameraState(),
  );

  /// Tail of pending platform operations; null when idle.
  static Future<void>? _platformQueue;

  CameraController? _controller;
  void Function(CameraImage frame)? _onFrame;
  bool _analysisPaused = false;
  bool _disposed = false;
  int _token = 0;

  ScanCameraSession({
    this.permissions = const PlatformCameraPermissionGateway(),
    this.resolution = ResolutionPreset.veryHigh,
    ImageFormatGroup? streamFormat,
  }) : streamFormat =
           streamFormat ??
           (defaultTargetPlatform == TargetPlatform.android
               ? ImageFormatGroup.yuv420
               : ImageFormatGroup.unknown);

  CameraController? get controller => _controller;

  @visibleForTesting
  static void resetPlatformQueue() => _platformQueue = null;

  static Future<T> _serialized<T>(Future<T> Function() action) {
    final previous = _platformQueue;
    final done = Completer<void>();
    _platformQueue = done.future;
    Future<T> run() async {
      try {
        return await action();
      } finally {
        if (identical(_platformQueue, done.future)) _platformQueue = null;
        done.complete();
      }
    }

    return previous == null ? run() : previous.then((_) => run());
  }

  void _emit(ScanCameraState value) {
    if (!_disposed) state.value = value;
  }

  /// Checks (and if [askPermission], requests) camera access, then opens the
  /// rear camera. Safe to call repeatedly; it is a no-op when already open.
  Future<void> open({bool askPermission = true}) async {
    if (_disposed || _controller != null) return;
    final token = ++_token;
    _emit(const ScanCameraState(status: ScanCameraStatus.checkingPermission));
    var permission = await permissions.status();
    if (permission == CameraPermissionStatus.denied && askPermission) {
      permission = await permissions.request();
    }
    if (token != _token || _disposed) return;
    if (permission != CameraPermissionStatus.granted) {
      _emit(
        ScanCameraState(
          status: permission == CameraPermissionStatus.permanentlyDenied
              ? ScanCameraStatus.permissionPermanentlyDenied
              : ScanCameraStatus.permissionRequired,
        ),
      );
      return;
    }
    _emit(const ScanCameraState(status: ScanCameraStatus.initializing));
    await _serialized(() async {
      if (token != _token || _disposed || _controller != null) return;
      CameraController? controller;
      try {
        final cameras = await availableCameras();
        if (cameras.isEmpty) {
          _emit(const ScanCameraState(status: ScanCameraStatus.noCamera));
          return;
        }
        final rear = cameras.where(
          (camera) => camera.lensDirection == CameraLensDirection.back,
        );
        controller = CameraController(
          rear.isEmpty ? cameras.first : rear.first,
          resolution,
          enableAudio: false,
          imageFormatGroup: streamFormat,
        );
        await controller.initialize();
        if (token != _token || _disposed) {
          await controller.dispose();
          return;
        }
        try {
          await controller.setFlashMode(FlashMode.off);
        } on CameraException {
          // Devices without a flash unit.
        }
        _controller = controller;
        _emit(
          ScanCameraState(
            status: ScanCameraStatus.ready,
            controller: controller,
          ),
        );
        await _startStream(controller);
      } on CameraException catch (error) {
        await controller?.dispose();
        _emit(
          ScanCameraState(
            status: error.code.startsWith('CameraAccess')
                ? ScanCameraStatus.permissionPermanentlyDenied
                : ScanCameraStatus.failed,
            error: error,
          ),
        );
      } catch (error) {
        await controller?.dispose();
        _emit(ScanCameraState(status: ScanCameraStatus.failed, error: error));
      }
    });
  }

  /// Releases the camera. Pending opens are cancelled.
  Future<void> close() {
    ++_token;
    return _serialized(() async {
      final controller = _controller;
      _controller = null;
      _emit(const ScanCameraState());
      if (controller == null) return;
      try {
        if (controller.value.isStreamingImages) {
          await controller.stopImageStream();
        }
      } on CameraException {
        // Disposing below releases the stream as well.
      }
      await controller.dispose();
    });
  }

  Future<void> dispose() async {
    await close();
    _disposed = true;
    state.dispose();
  }

  /// Registers the live frame consumer. Pass null to stop streaming.
  Future<void> setFrameListener(void Function(CameraImage frame)? onFrame) {
    _onFrame = onFrame;
    return _serialized(() async {
      final controller = _controller;
      if (controller == null) return;
      if (onFrame == null) {
        await _stopStream(controller);
      } else {
        await _startStream(controller);
      }
    });
  }

  Future<void> pauseAnalysis() {
    _analysisPaused = true;
    return _serialized(() async {
      final controller = _controller;
      if (controller != null) await _stopStream(controller);
    });
  }

  Future<void> resumeAnalysis() {
    _analysisPaused = false;
    return _serialized(() async {
      final controller = _controller;
      if (controller != null) await _startStream(controller);
    });
  }

  Future<void> _startStream(CameraController controller) async {
    final onFrame = _onFrame;
    if (onFrame == null ||
        _analysisPaused ||
        !state.value.liveAnalysisAvailable ||
        defaultTargetPlatform != TargetPlatform.android ||
        !controller.value.isInitialized ||
        controller.value.isStreamingImages) {
      return;
    }
    try {
      await controller.startImageStream(onFrame);
    } catch (_) {
      markLiveAnalysisUnavailable();
    }
  }

  Future<void> _stopStream(CameraController controller) async {
    if (!controller.value.isStreamingImages) return;
    try {
      await controller.stopImageStream();
    } on CameraException {
      // Stream already stopped by the platform.
    }
  }

  void markLiveAnalysisUnavailable() {
    if (state.value.liveAnalysisAvailable) {
      _emit(state.value.copyWith(liveAnalysisAvailable: false));
    }
  }

  /// Captures a still image. Live analysis is paused for the duration so the
  /// encoder does not compete with frame copies.
  Future<Uint8List> takePicture() => _serialized(() async {
    final controller = _controller;
    if (controller == null || !controller.value.isInitialized) {
      throw CameraException('cameraNotReady', 'The camera is not ready.');
    }
    await _stopStream(controller);
    try {
      final capture = await controller.takePicture();
      try {
        return await capture.readAsBytes();
      } finally {
        try {
          await File(capture.path).delete();
        } on FileSystemException {
          // Plugin-owned temp file already removed.
        }
      }
    } finally {
      if (_controller == controller) await _startStream(controller);
    }
  });

  Future<void> setTorch(bool on) => _serialized(() async {
    final controller = _controller;
    if (controller == null) return;
    await controller.setFlashMode(on ? FlashMode.torch : FlashMode.off);
    if (_controller == controller) _emit(state.value.copyWith(torchOn: on));
  });

  /// [point] is normalized to the (rotated, uncropped) preview.
  Future<void> focusAt(Offset point) => _serialized(() async {
    final controller = _controller;
    if (controller == null) return;
    if (controller.value.focusPointSupported) {
      await controller.setFocusPoint(point);
    }
    if (controller.value.exposurePointSupported) {
      await controller.setExposurePoint(point);
    }
  });
}
