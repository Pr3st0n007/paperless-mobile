import 'dart:math';
import 'dart:typed_data';

import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';

enum ScanAutoCaptureSpeed {
  quick(Duration(seconds: 1)),
  balanced(Duration(seconds: 2)),
  careful(Duration(seconds: 3));

  const ScanAutoCaptureSpeed(this.duration);

  final Duration duration;
}

class ScanAutoCaptureCountdown {
  ScanAutoCaptureSpeed _speed;
  DateTime? _stableSince;

  ScanAutoCaptureCountdown({
    ScanAutoCaptureSpeed speed = ScanAutoCaptureSpeed.balanced,
  }) : _speed = speed;

  ScanAutoCaptureSpeed get speed => _speed;
  bool get isActive => _stableSince != null;

  Duration elapsedAt(DateTime now) {
    final stableSince = _stableSince;
    if (stableSince == null) return Duration.zero;
    final elapsed = now.difference(stableSince);
    return elapsed.isNegative ? Duration.zero : elapsed;
  }

  double progressAt(DateTime now) =>
      (elapsedAt(now).inMicroseconds / _speed.duration.inMicroseconds)
          .clamp(0, 1)
          .toDouble();

  Duration remainingAt(DateTime now) {
    final remaining = _speed.duration - elapsedAt(now);
    return remaining.isNegative ? Duration.zero : remaining;
  }

  bool update({
    required bool stable,
    required bool qualityAcceptable,
    DateTime? now,
  }) {
    if (!stable || !qualityAcceptable) {
      reset();
      return false;
    }
    final currentTime = now ?? DateTime.now();
    _stableSince ??= currentTime;
    return progressAt(currentTime) >= 1;
  }

  void setSpeed(ScanAutoCaptureSpeed speed) {
    if (_speed == speed) return;
    _speed = speed;
    reset();
  }

  void reset() => _stableSince = null;
}

bool hasClearPageChange(
  Uint8List previous,
  Uint8List current, {
  double hammingThreshold = 0.22,
}) {
  if (previous.length != current.length || previous.isEmpty) return false;
  var differences = 0;
  for (var i = 0; i < previous.length; i++) {
    if (previous[i] != current[i]) differences++;
  }
  return differences / previous.length >= hammingThreshold;
}

class ScanAutoCaptureGate {
  bool _enabled = false;
  bool _armed = true;
  bool _waitingForNextPage = false;
  int _missingFrames = 0;
  List<Point<double>>? _capturedCorners;
  Uint8List? _capturedFingerprint;

  bool get canCapture => _enabled && _armed && !_waitingForNextPage;

  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (enabled && !_waitingForNextPage) _armed = true;
  }

  bool shouldCapture({
    required bool stable,
    required bool qualityAcceptable,
    required bool retaking,
  }) {
    if (!_enabled ||
        !_armed ||
        !stable ||
        !qualityAcceptable ||
        retaking) {
      return false;
    }
    _armed = false;
    return true;
  }

  void captureFailed() {
    if (_enabled && !_waitingForNextPage) _armed = true;
  }

  void pageCaptured({
    required List<Point<double>>? corners,
    required Uint8List? fingerprint,
  }) {
    _armed = false;
    _waitingForNextPage = true;
    _missingFrames = 0;
    _capturedCorners = corners == null ? null : List.unmodifiable(corners);
    _capturedFingerprint = fingerprint == null
        ? null
        : Uint8List.fromList(fingerprint);
  }

  bool observe({
    required List<Point<double>>? corners,
    required Uint8List fingerprint,
  }) {
    if (!_waitingForNextPage) return false;
    if (corners == null) {
      _missingFrames++;
      if (_missingFrames < 5) return false;
      _rearm();
      return true;
    }
    _missingFrames = 0;
    final captured = _capturedCorners;
    if (captured != null &&
        (_maxCornerMovement(corners, captured) > 0.18 ||
            hasClearPageChange(
              _capturedFingerprint ?? Uint8List(0),
              fingerprint,
            ))) {
      _rearm();
      return true;
    }
    return false;
  }

  void _rearm() {
    _waitingForNextPage = false;
    _armed = true;
    _capturedCorners = null;
    _capturedFingerprint = null;
  }

  double _maxCornerMovement(
    List<Point<double>> a,
    List<Point<double>> b,
  ) {
    var movement = 0.0;
    for (var i = 0; i < 4; i++) {
      movement = max(movement, a[i].distanceTo(b[i]));
    }
    return movement;
  }
}

enum ScanBoundaryStatus { uncertain, stable }

class ScanBoundaryUpdate {
  final ScanBoundaryStatus status;
  final List<Point<double>>? corners;
  final bool transitionedToStable;
  final bool transitionedToUnstable;

  const ScanBoundaryUpdate({
    required this.status,
    required this.corners,
    required this.transitionedToStable,
    required this.transitionedToUnstable,
  });
}

/// Requires consecutive valid detections whose corners stay within a small
/// fraction of the preview frame. Any missed or jumping result resets it.
class ScanBoundaryStability {
  final int requiredFrames;
  final double maximumCornerMovement;
  List<Point<double>>? _previous;
  int _consecutive = 0;
  bool _stable = false;

  ScanBoundaryStability({
    this.requiredFrames = 4,
    this.maximumCornerMovement = 0.035,
  }) : assert(requiredFrames > 0),
       assert(maximumCornerMovement > 0);

  ScanBoundaryUpdate update(List<Point<double>>? corners) {
    final wasStable = _stable;
    if (corners == null || !ScanEdit.isValidCorners(corners)) {
      _previous = null;
      _consecutive = 0;
      _stable = false;
    } else {
      final previous = _previous;
      final moved = previous == null ||
          List.generate(
            4,
            (i) => corners[i].distanceTo(previous[i]),
          ).any((distance) => distance > maximumCornerMovement);
      _consecutive = moved ? 1 : _consecutive + 1;
      _previous = List.unmodifiable(corners);
      _stable = _consecutive >= requiredFrames;
    }
    return ScanBoundaryUpdate(
      status: _stable
          ? ScanBoundaryStatus.stable
          : ScanBoundaryStatus.uncertain,
      corners: corners == null ? null : List.unmodifiable(corners),
      transitionedToStable: !wasStable && _stable,
      transitionedToUnstable: wasStable && !_stable,
    );
  }
}
