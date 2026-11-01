import 'dart:math';
import 'dart:ui' show lerpDouble;

import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_preview_transform.dart';

/// Animated live boundary overlay drawn in viewport space.
///
/// Corners glide between analysis results instead of jumping (analysis runs at
/// 4–15 Hz), the area outside the page is dimmed, and the auto-capture
/// countdown is drawn as a stroke travelling around the page outline.
class DocumentOverlay extends StatefulWidget {
  final CaptureReadiness readiness;

  /// Size of the uncropped preview box the normalized corners refer to.
  final Size sourceSize;

  /// Auto-capture countdown in [0, 1].
  final Animation<double> countdown;

  const DocumentOverlay({
    super.key,
    required this.readiness,
    required this.sourceSize,
    required this.countdown,
  });

  @override
  State<DocumentOverlay> createState() => _DocumentOverlayState();
}

class _DocumentOverlayState extends State<DocumentOverlay>
    with TickerProviderStateMixin {
  late final _motion = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 140),
  );
  late final _visibility = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 220),
  );
  List<Point<double>>? _from;
  List<Point<double>>? _to;

  @override
  void initState() {
    super.initState();
    _apply(widget.readiness.corners, animate: false);
  }

  @override
  void didUpdateWidget(DocumentOverlay oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!identical(oldWidget.readiness.corners, widget.readiness.corners)) {
      _apply(
        widget.readiness.corners,
        animate: !MediaQuery.of(context).disableAnimations,
      );
    }
  }

  void _apply(List<Point<double>>? corners, {required bool animate}) {
    if (corners == null) {
      _visibility.reverse();
      return;
    }
    final wasVisible = _to != null && _visibility.value > 0;
    _from = wasVisible ? _current : corners;
    _to = corners;
    if (animate && wasVisible) {
      _motion.forward(from: 0);
    } else {
      _motion.value = 1;
    }
    animate ? _visibility.forward() : _visibility.value = 1;
  }

  List<Point<double>>? get _current {
    final from = _from;
    final to = _to;
    if (from == null || to == null) return to;
    final t = Curves.easeOut.transform(_motion.value);
    return List.generate(
      4,
      (i) => Point(
        lerpDouble(from[i].x, to[i].x, t)!,
        lerpDouble(from[i].y, to[i].y, t)!,
      ),
    );
  }

  @override
  void dispose() {
    _motion.dispose();
    _visibility.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    return IgnorePointer(
      child: RepaintBoundary(
        child: CustomPaint(
          size: Size.infinite,
          painter: _OverlayPainter(
            repaint: Listenable.merge([_motion, _visibility, widget.countdown]),
            corners: () => _current,
            visibility: _visibility,
            countdown: widget.countdown,
            sourceSize: widget.sourceSize,
            phase: widget.readiness.phase,
            accent: scheme.primary,
          ),
        ),
      ),
    );
  }
}

class _OverlayPainter extends CustomPainter {
  static const _confirmed = Color(0xFF4ADE80);
  static const _warning = Color(0xFFFBBF24);

  final List<Point<double>>? Function() corners;
  final Animation<double> visibility;
  final Animation<double> countdown;
  final Size sourceSize;
  final CapturePhase phase;
  final Color accent;

  _OverlayPainter({
    required Listenable repaint,
    required this.corners,
    required this.visibility,
    required this.countdown,
    required this.sourceSize,
    required this.phase,
    required this.accent,
  }) : super(repaint: repaint);

  Color get _color => switch (phase) {
    CapturePhase.searching || CapturePhase.settling => Colors.white,
    CapturePhase.adjusting => _warning,
    CapturePhase.holding => Colors.white,
    CapturePhase.ready ||
    CapturePhase.triggered ||
    CapturePhase.waitingForNextPage => _confirmed,
  };

  @override
  void paint(Canvas canvas, Size size) {
    final points = corners();
    final opacity = visibility.value;
    if (points == null || opacity == 0 || size.isEmpty || sourceSize.isEmpty) {
      return;
    }
    final mapped = ScanPreviewTransform.mapToViewport(
      corners: points,
      sourceWidth: sourceSize.width,
      sourceHeight: sourceSize.height,
      viewportWidth: size.width,
      viewportHeight: size.height,
    ).map((p) => Offset(p.x, p.y)).toList();
    final page = Path()..addPolygon(mapped, true);
    final color = _color;

    canvas.drawPath(
      Path()
        ..fillType = PathFillType.evenOdd
        ..addRect(Offset.zero & size)
        ..addPath(page, Offset.zero),
      Paint()..color = Colors.black.withValues(alpha: 0.35 * opacity),
    );
    canvas.drawPath(
      page,
      Paint()..color = color.withValues(alpha: 0.12 * opacity),
    );
    canvas.drawPath(
      page,
      Paint()
        ..color = color.withValues(alpha: 0.9 * opacity)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2.5
        ..strokeJoin = StrokeJoin.round,
    );

    final progress = countdown.value;
    if (progress > 0 &&
        (phase == CapturePhase.holding || phase == CapturePhase.triggered)) {
      final metric = page.computeMetrics().first;
      canvas.drawPath(
        metric.extractPath(0, metric.length * progress),
        Paint()
          ..color = Color.lerp(accent, _confirmed, progress)!.withValues(
            alpha: opacity,
          )
          ..style = PaintingStyle.stroke
          ..strokeWidth = 5
          ..strokeCap = StrokeCap.round,
      );
    }

    final handle = Paint()..color = color.withValues(alpha: opacity);
    final outline = Paint()
      ..color = Colors.black.withValues(alpha: 0.5 * opacity)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.5;
    for (final point in mapped) {
      canvas.drawCircle(point, 7, handle);
      canvas.drawCircle(point, 7, outline);
    }
  }

  // Rebuilt only when a new analysis result arrives.
  @override
  bool shouldRepaint(_OverlayPainter old) => true;
}
