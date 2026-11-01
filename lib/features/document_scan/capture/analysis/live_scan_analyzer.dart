import 'dart:async';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/capture/analysis/camera_frame_converter.dart';
import 'package:paperless_mobile/features/document_scan/capture/analysis/frame_analysis_worker.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_preview_transform.dart';

/// Turns the camera stream into [CaptureReadiness] updates.
///
/// Frames are dropped while an analysis is in flight and paced adaptively to
/// the measured analysis time, so slow devices analyze less often instead of
/// queueing work and stalling the preview. Only [readiness] listeners rebuild
/// per frame; the rest of the screen is unaffected.
class LiveScanAnalyzer {
  final AutoCaptureController autoCapture;
  final ScanCaptureTuning tuning;
  final FrameAnalysisWorker _worker;
  final ValueNotifier<CaptureReadiness> readiness = ValueNotifier(
    CaptureReadiness.initial,
  );

  /// Invoked once when frames arrive in a format the converter cannot read.
  final VoidCallback onUnsupportedFormat;

  final _clock = Stopwatch()..start();
  bool _inFlight = false;
  bool _disposed = false;
  int _generation = 0;
  Duration _lastStart = -const Duration(days: 1);
  late Duration _interval = tuning.minAnalysisInterval;

  List<Point<double>>? _lastCorners;
  Uint8List? _lastFingerprint;

  LiveScanAnalyzer({
    required this.autoCapture,
    required this.onUnsupportedFormat,
    this.tuning = ScanCaptureTuning.standard,
    FrameAnalysisWorker? worker,
  }) : _worker = worker ?? FrameAnalysisWorker();

  List<Point<double>>? get lastCorners => _lastCorners;
  Uint8List? get lastFingerprint => _lastFingerprint;

  void onFrame(CameraImage frame, int rotation) {
    final now = _clock.elapsed;
    if (_disposed || _inFlight || now - _lastStart < _interval) return;
    _inFlight = true;
    _lastStart = now;
    unawaited(_analyze(frame, rotation, now));
  }

  Future<void> _analyze(CameraImage frame, int rotation, Duration start) async {
    final generation = _generation;
    try {
      final input = CameraFrameConverter.toPackedRgb(
        frame,
        longestSide: tuning.analysisLongestSide,
      );
      final analysis = await _worker.analyze(input);
      if (_disposed || generation != _generation) return;
      final detected = analysis.detectedCorners;
      final corners = detected == null
          ? null
          : ScanPreviewTransform.rotateCorners(detected, rotation);
      _lastCorners = corners;
      _lastFingerprint = analysis.pageFingerprint;
      readiness.value = autoCapture.observe(
        FrameObservation(
          timestamp: start,
          corners: corners,
          quality: analysis.quality,
          fingerprint: analysis.pageFingerprint,
        ),
      );
    } on FormatException {
      if (!_disposed) onUnsupportedFormat();
    } on StateError {
      // Worker closed while disposing.
    } finally {
      final took = _clock.elapsed - start;
      _interval = Duration(
        microseconds: (took.inMicroseconds * 1.25).round().clamp(
          tuning.minAnalysisInterval.inMicroseconds,
          tuning.maxAnalysisInterval.inMicroseconds,
        ),
      );
      _inFlight = false;
    }
  }

  /// Discards in-flight results and resets readiness, e.g. after a capture,
  /// a settings change or a camera restart.
  void invalidate({bool resetAutoCapture = false}) {
    _generation++;
    if (resetAutoCapture) autoCapture.reset();
    _lastCorners = null;
    if (!_disposed) {
      readiness.value = resetAutoCapture
          ? CaptureReadiness.initial
          : autoCapture.readiness;
    }
  }

  void dispose() {
    _disposed = true;
    _generation++;
    _worker.close();
    readiness.dispose();
  }
}
