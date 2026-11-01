import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';

enum CapturePhase {
  /// No usable document boundary in view.
  searching,

  /// A document is visible but something blocks capture (see [CaptureGuidance]).
  adjusting,

  /// Manual mode: document found, waiting for [ScanCaptureTuning.stableConfirmation].
  settling,

  /// Auto mode: countdown towards capture is running.
  holding,

  /// Manual mode: stable and ready for the shutter.
  ready,

  /// Auto mode: countdown completed; the caller must capture now.
  triggered,

  /// Auto mode: the last page is still in view; waiting for a new page.
  waitingForNextPage,
}

enum CaptureGuidance {
  searching,
  moveCloser,
  tooDark,
  tooBright,
  blurry,
  holdSteady,
  holding,
  ready,
  capturing,
  nextPage,
}

@immutable
class FrameObservation {
  /// Monotonic time of the analyzed frame.
  final Duration timestamp;
  final List<Point<double>>? corners;
  final ScanQualityAssessment? quality;
  final Uint8List? fingerprint;

  const FrameObservation({
    required this.timestamp,
    this.corners,
    this.quality,
    this.fingerprint,
  });
}

@immutable
class CaptureReadiness {
  final CapturePhase phase;
  final CaptureGuidance guidance;
  final List<Point<double>>? corners;

  /// Countdown progress in [0, 1] while [phase] is [CapturePhase.holding].
  final double progress;

  /// Remaining countdown, used by the UI to animate smoothly between frames.
  final Duration remaining;

  const CaptureReadiness({
    required this.phase,
    required this.guidance,
    this.corners,
    this.progress = 0,
    this.remaining = Duration.zero,
  });

  static const initial = CaptureReadiness(
    phase: CapturePhase.searching,
    guidance: CaptureGuidance.searching,
  );

  bool get shouldCapture => phase == CapturePhase.triggered;

  /// The outline is shown as confirmed only once a document has been still
  /// long enough; this is what green means to the user.
  bool get isStable =>
      phase == CapturePhase.ready ||
      phase == CapturePhase.triggered ||
      (phase == CapturePhase.holding && progress > 0) ||
      phase == CapturePhase.waitingForNextPage;
}

/// Time-based auto-capture state machine. Pure Dart and clock-free (timestamps
/// come from the frames) so it is deterministic in tests.
///
/// A capture is triggered only after every analyzed frame within the selected
/// [AutoCaptureSpeed.holdDuration] showed a valid, large enough, sharp and
/// exposed document whose corners stayed within
/// [ScanCaptureTuning.holdMovementTolerance] of where the hold started.
class AutoCaptureController {
  final ScanCaptureTuning tuning;
  bool _enabled;
  bool _suspended = false;
  AutoCaptureSpeed _speed;

  Duration? _holdStart;
  List<Point<double>>? _anchor;
  int _missedFrames = 0;
  bool _triggered = false;
  CaptureReadiness _last = CaptureReadiness.initial;

  bool _waitingForNextPage = false;
  List<Point<double>>? _capturedCorners;
  Uint8List? _capturedFingerprint;
  Duration? _absentSince;

  AutoCaptureController({
    this.tuning = ScanCaptureTuning.standard,
    bool enabled = false,
    AutoCaptureSpeed speed = AutoCaptureSpeed.defaultSpeed,
  }) : _enabled = enabled,
       _speed = speed;

  bool get enabled => _enabled;
  AutoCaptureSpeed get speed => _speed;
  CaptureReadiness get readiness => _last;
  bool get _autoActive => _enabled && !_suspended;

  set enabled(bool value) {
    if (value == _enabled) return;
    _enabled = value;
    _resetHold();
  }

  set speed(AutoCaptureSpeed value) {
    if (value == _speed) return;
    _speed = value;
    _resetHold();
  }

  /// Suspends auto capture (e.g. while retaking a specific page) without
  /// losing guidance feedback.
  set suspended(bool value) {
    if (value == _suspended) return;
    _suspended = value;
    _resetHold();
  }

  CaptureReadiness observe(FrameObservation frame) {
    final raw = frame.corners;
    final corners = raw != null && ScanEdit.isValidCorners(raw) ? raw : null;
    _updateRearm(frame.timestamp, corners, frame.fingerprint);

    final blocker = _blockerFor(corners, frame.quality);
    if (blocker != null) {
      if (corners == null &&
          _holdStart != null &&
          _missedFrames < tuning.holdMissedFrameTolerance) {
        _missedFrames++;
        return _last;
      }
      _resetHold();
      return _last = CaptureReadiness(
        phase: corners == null ? CapturePhase.searching : CapturePhase.adjusting,
        guidance: blocker,
        corners: corners,
      );
    }
    _missedFrames = 0;

    if (_autoActive && _waitingForNextPage) {
      _resetHold();
      return _last = CaptureReadiness(
        phase: CapturePhase.waitingForNextPage,
        guidance: CaptureGuidance.nextPage,
        corners: corners,
      );
    }

    final anchor = _anchor;
    final moved =
        anchor != null && _maxDistance(anchor, corners!) > tuning.holdMovementTolerance;
    if (_holdStart == null || moved) {
      _holdStart = frame.timestamp;
      _anchor = List.unmodifiable(corners!);
      _triggered = false;
    }
    final elapsed = frame.timestamp - _holdStart!;

    if (!_autoActive) {
      final confirmed = elapsed >= tuning.stableConfirmation;
      return _last = CaptureReadiness(
        phase: confirmed ? CapturePhase.ready : CapturePhase.settling,
        guidance: confirmed ? CaptureGuidance.ready : CaptureGuidance.holdSteady,
        corners: corners,
      );
    }

    final hold = _speed.holdDuration;
    if (_triggered || elapsed >= hold) {
      _triggered = true;
      return _last = CaptureReadiness(
        phase: CapturePhase.triggered,
        guidance: CaptureGuidance.capturing,
        corners: corners,
        progress: 1,
      );
    }
    return _last = CaptureReadiness(
      phase: CapturePhase.holding,
      guidance: moved ? CaptureGuidance.holdSteady : CaptureGuidance.holding,
      corners: corners,
      progress: elapsed.inMicroseconds / hold.inMicroseconds,
      remaining: hold - elapsed,
    );
  }

  /// Call after any capture (manual or automatic) so the same page is not
  /// captured again while it stays in view.
  void pageCaptured({List<Point<double>>? corners, Uint8List? fingerprint}) {
    _resetHold();
    _waitingForNextPage = true;
    _absentSince = null;
    _capturedCorners = corners == null ? null : List.unmodifiable(corners);
    _capturedFingerprint = fingerprint == null
        ? null
        : Uint8List.fromList(fingerprint);
  }

  /// Call when a triggered capture could not be completed.
  void captureAborted() => _resetHold();

  /// Forget all state, e.g. after the camera restarted.
  void reset() {
    _resetHold();
    _waitingForNextPage = false;
    _capturedCorners = null;
    _capturedFingerprint = null;
    _absentSince = null;
    _last = CaptureReadiness.initial;
  }

  CaptureGuidance? _blockerFor(
    List<Point<double>>? corners,
    ScanQualityAssessment? quality,
  ) {
    if (corners == null) return CaptureGuidance.searching;
    if (_area(corners) < tuning.minimumDocumentArea) {
      return CaptureGuidance.moveCloser;
    }
    if (quality == null) return null;
    if (quality.isTooDark) return CaptureGuidance.tooDark;
    if (quality.isTooBright) return CaptureGuidance.tooBright;
    if (quality.isBlurry) return CaptureGuidance.blurry;
    return null;
  }

  void _updateRearm(
    Duration timestamp,
    List<Point<double>>? corners,
    Uint8List? fingerprint,
  ) {
    if (!_waitingForNextPage) return;
    if (corners == null) {
      _absentSince ??= timestamp;
      if (timestamp - _absentSince! >= tuning.rearmAbsence) _rearm();
      return;
    }
    _absentSince = null;
    final captured = _capturedCorners;
    final previousFingerprint = _capturedFingerprint;
    if ((captured != null &&
            _maxDistance(captured, corners) > tuning.rearmCornerMovement) ||
        (previousFingerprint != null &&
            fingerprint != null &&
            hasClearPageChange(previousFingerprint, fingerprint))) {
      _rearm();
    }
  }

  void _rearm() {
    _waitingForNextPage = false;
    _capturedCorners = null;
    _capturedFingerprint = null;
    _absentSince = null;
    _resetHold();
  }

  void _resetHold() {
    _holdStart = null;
    _anchor = null;
    _missedFrames = 0;
    _triggered = false;
  }

  static double _maxDistance(List<Point<double>> a, List<Point<double>> b) {
    var result = 0.0;
    for (var i = 0; i < 4; i++) {
      result = max(result, a[i].distanceTo(b[i]));
    }
    return result;
  }

  static double _area(List<Point<double>> points) {
    var sum = 0.0;
    for (var i = 0; i < points.length; i++) {
      final a = points[i];
      final b = points[(i + 1) % points.length];
      sum += a.x * b.y - b.x * a.y;
    }
    return sum.abs() / 2;
  }
}
