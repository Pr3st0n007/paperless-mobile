import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';

const _page = [
  Point(0.2, 0.15),
  Point(0.8, 0.15),
  Point(0.8, 0.85),
  Point(0.2, 0.85),
];

List<Point<double>> _shift(double dx) =>
    _page.map((p) => Point(p.x + dx, p.y)).toList();

const _good = ScanQualityAssessment(
  edgeSharpness: 20,
  underexposedFraction: 0,
  clippedFraction: 0,
  glareLikeFraction: 0,
);

FrameObservation _frame(
  int ms, {
  List<Point<double>>? corners = _page,
  ScanQualityAssessment quality = _good,
  Uint8List? fingerprint,
}) => FrameObservation(
  timestamp: Duration(milliseconds: ms),
  corners: corners,
  quality: quality,
  fingerprint: fingerprint,
);

/// Feeds frames every [step] ms from [from] to [to] (inclusive) and returns
/// the last readiness.
CaptureReadiness _run(
  AutoCaptureController controller,
  int from,
  int to, {
  int step = 100,
  List<Point<double>>? corners = _page,
}) {
  late CaptureReadiness last;
  for (var t = from; t <= to; t += step) {
    last = controller.observe(_frame(t, corners: corners));
  }
  return last;
}

void main() {
  group('AutoCaptureController', () {
    test('each speed waits for its full hold duration', () {
      for (final speed in AutoCaptureSpeed.values) {
        final controller = AutoCaptureController(enabled: true, speed: speed);
        final hold = speed.holdDuration.inMilliseconds;
        final before = _run(controller, 0, hold - 100);
        expect(before.phase, CapturePhase.holding, reason: '$speed');
        expect(before.shouldCapture, isFalse);
        expect(before.progress, closeTo((hold - 100) / hold, 1e-6));
        final at = controller.observe(_frame(hold));
        expect(at.shouldCapture, isTrue, reason: '$speed');
      }
    });

    test('presets are ordered from slowest to fastest', () {
      expect(
        AutoCaptureSpeed.relaxed.holdDuration,
        greaterThan(AutoCaptureSpeed.balanced.holdDuration),
      );
      expect(
        AutoCaptureSpeed.balanced.holdDuration,
        greaterThan(AutoCaptureSpeed.fast.holdDuration),
      );
    });

    test('significant movement restarts the countdown', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
      );
      _run(controller, 0, 700);
      final moved = controller.observe(_frame(750, corners: _shift(0.05)));
      expect(moved.phase, CapturePhase.holding);
      expect(moved.guidance, CaptureGuidance.holdSteady);
      expect(moved.progress, 0);
      expect(_run(controller, 800, 1500, corners: _shift(0.05)).shouldCapture, isFalse);
      expect(controller.observe(_frame(1550, corners: _shift(0.05))).shouldCapture, isTrue);
    });

    test('slow drift is measured from the hold anchor, not per frame', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.relaxed,
      );
      CaptureReadiness? last;
      // 0.01 per frame never exceeds the per-step tolerance but accumulates.
      for (var i = 0; i <= 20; i++) {
        last = controller.observe(_frame(i * 100, corners: _shift(i * 0.01)));
      }
      expect(last!.shouldCapture, isFalse);
    });

    test('quality drops reset the countdown with specific guidance', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
      );
      _run(controller, 0, 700);
      final blurry = controller.observe(
        _frame(
          750,
          quality: const ScanQualityAssessment(
            edgeSharpness: 1,
            underexposedFraction: 0,
            clippedFraction: 0,
            glareLikeFraction: 0,
          ),
        ),
      );
      expect(blurry.phase, CapturePhase.adjusting);
      expect(blurry.guidance, CaptureGuidance.blurry);
      expect(_run(controller, 800, 1500).shouldCapture, isFalse);
    });

    test('small documents ask the user to move closer', () {
      final controller = AutoCaptureController(enabled: true);
      final result = controller.observe(
        _frame(
          0,
          corners: const [
            Point(0.4, 0.4),
            Point(0.6, 0.4),
            Point(0.6, 0.6),
            Point(0.4, 0.6),
          ],
        ),
      );
      expect(result.guidance, CaptureGuidance.moveCloser);
    });

    test('a single missed detection is tolerated but never completes the hold', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
      );
      _run(controller, 0, 700);
      final missed = controller.observe(_frame(800, corners: null));
      expect(missed.shouldCapture, isFalse);
      expect(missed.phase, CapturePhase.holding);
      expect(controller.observe(_frame(850)).shouldCapture, isTrue);
    });

    test('two missed detections restart the countdown', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
      );
      _run(controller, 0, 600);
      controller.observe(_frame(650, corners: null));
      final lost = controller.observe(_frame(700, corners: null));
      expect(lost.phase, CapturePhase.searching);
      expect(_run(controller, 750, 1450).shouldCapture, isFalse);
    });

    test('manual mode turns ready after the stable confirmation only', () {
      final controller = AutoCaptureController();
      expect(controller.observe(_frame(0)).phase, CapturePhase.settling);
      expect(controller.observe(_frame(300)).phase, CapturePhase.settling);
      final ready = controller.observe(_frame(400));
      expect(ready.phase, CapturePhase.ready);
      expect(ready.shouldCapture, isFalse);
      expect(_run(controller, 500, 5000).shouldCapture, isFalse);
    });

    test('suspension and speed changes reset the countdown', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
      );
      _run(controller, 0, 700);
      controller.speed = AutoCaptureSpeed.relaxed;
      expect(controller.observe(_frame(800)).progress, 0);
      controller.suspended = true;
      expect(_run(controller, 900, 5000).shouldCapture, isFalse);
    });

    test('same page is not captured twice; rearms after absence or change', () {
      final controller = AutoCaptureController(
        enabled: true,
        speed: AutoCaptureSpeed.fast,
        tuning: const ScanCaptureTuning(rearmAbsence: Duration(milliseconds: 500)),
      );
      final fingerprint = Uint8List(256);
      controller.pageCaptured(corners: _page, fingerprint: fingerprint);
      for (var t = 0; t <= 3000; t += 100) {
        final r = controller.observe(_frame(t, fingerprint: fingerprint));
        expect(r.phase, CapturePhase.waitingForNextPage);
      }
      for (var t = 3100; t < 3600; t += 100) {
        controller.observe(_frame(t, corners: null));
      }
      expect(
        controller.observe(_frame(3600, corners: null)).phase,
        CapturePhase.searching,
      );
      expect(controller.observe(_frame(3700)).phase, CapturePhase.holding);

      controller.pageCaptured(corners: _page, fingerprint: fingerprint);
      final changed = controller.observe(
        _frame(3800, fingerprint: Uint8List.fromList(List.filled(256, 1))),
      );
      expect(changed.phase, CapturePhase.holding);
    });
  });
}
