import 'package:flutter/foundation.dart';

/// How long a document must stay detected, sharp, exposed and still before
/// auto capture fires.
enum AutoCaptureSpeed {
  relaxed(Duration(milliseconds: 2000)),
  balanced(Duration(milliseconds: 1300)),
  fast(Duration(milliseconds: 800));

  const AutoCaptureSpeed(this.holdDuration);

  final Duration holdDuration;

  static const defaultSpeed = AutoCaptureSpeed.balanced;
}

/// Central thresholds for live detection and auto capture. Values are starting
/// points pending the device acceptance matrix in docs/android-document-scanner.md.
@immutable
class ScanCaptureTuning {
  /// Maximum normalized distance any corner may drift from where the hold
  /// started before the countdown restarts.
  final double holdMovementTolerance;

  /// Consecutive missed detections tolerated during a hold. Missed frames never
  /// advance or complete the countdown; they only avoid restarting it.
  final int holdMissedFrameTolerance;

  /// Manual mode: time a document must be stable before the outline turns green.
  final Duration stableConfirmation;

  /// Documents covering less of the frame than this prompt "move closer".
  final double minimumDocumentArea;

  /// After a capture, the page must disappear for this long before auto
  /// capture rearms (unless it moved or changed clearly).
  final Duration rearmAbsence;

  /// After a capture, corner movement above this rearms auto capture.
  final double rearmCornerMovement;

  /// Live analysis pacing. The effective interval adapts to the measured
  /// analysis duration between these bounds to keep low-end devices responsive.
  final Duration minAnalysisInterval;
  final Duration maxAnalysisInterval;

  /// Longest edge of the frame handed to the detector.
  final int analysisLongestSide;

  const ScanCaptureTuning({
    this.holdMovementTolerance = 0.03,
    this.holdMissedFrameTolerance = 1,
    this.stableConfirmation = const Duration(milliseconds: 400),
    this.minimumDocumentArea = 0.12,
    this.rearmAbsence = const Duration(milliseconds: 600),
    this.rearmCornerMovement = 0.18,
    this.minAnalysisInterval = const Duration(milliseconds: 70),
    this.maxAnalysisInterval = const Duration(milliseconds: 300),
    this.analysisLongestSide = 320,
  });

  static const standard = ScanCaptureTuning();
}
