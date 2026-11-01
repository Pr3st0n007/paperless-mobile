import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_preview_transform.dart';

/// Full-bleed camera preview (BoxFit.cover) with tap-to-focus.
///
/// [overlayBuilder] receives the uncropped preview size so overlays can map
/// normalized coordinates through the same cover crop as the preview.
class CameraViewport extends StatefulWidget {
  final CameraController controller;
  final Widget Function(BuildContext context, Size sourceSize) overlayBuilder;
  final ValueChanged<Offset> onFocus;

  const CameraViewport({
    super.key,
    required this.controller,
    required this.overlayBuilder,
    required this.onFocus,
  });

  @override
  State<CameraViewport> createState() => _CameraViewportState();
}

class _CameraViewportState extends State<CameraViewport>
    with SingleTickerProviderStateMixin {
  late final AnimationController _focusRing;
  Offset? _focusPoint;

  @override
  void initState() {
    super.initState();
    _focusRing = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
  }

  @override
  void dispose() {
    _focusRing.dispose();
    super.dispose();
  }

  static Size _sourceSize(CameraValue value) {
    final preview = value.previewSize ?? const Size(1920, 1080);
    final landscape = const [
      DeviceOrientation.landscapeLeft,
      DeviceOrientation.landscapeRight,
    ].contains(value.lockedCaptureOrientation ?? value.deviceOrientation);
    final long = max(preview.width, preview.height);
    final short = min(preview.width, preview.height);
    return landscape ? Size(long, short) : Size(short, long);
  }

  void _handleTap(TapUpDetails details, Size viewport, Size source) {
    final normalized = ScanPreviewTransform.viewportToSource(
      point: Point(details.localPosition.dx, details.localPosition.dy),
      sourceWidth: source.width,
      sourceHeight: source.height,
      viewportWidth: viewport.width,
      viewportHeight: viewport.height,
    );
    setState(() => _focusPoint = details.localPosition);
    _focusRing.forward(from: 0);
    widget.onFocus(Offset(normalized.x, normalized.y));
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<CameraValue>(
      valueListenable: widget.controller,
      builder: (context, value, _) {
        final source = _sourceSize(value);
        return LayoutBuilder(
          builder: (context, constraints) {
            final viewport = constraints.biggest;
            return GestureDetector(
              behavior: HitTestBehavior.opaque,
              onTapUp: (details) => _handleTap(details, viewport, source),
              child: Stack(
                fit: StackFit.expand,
                children: [
                  ClipRect(
                    child: FittedBox(
                      fit: BoxFit.cover,
                      child: SizedBox.fromSize(
                        size: source,
                        child: CameraPreview(widget.controller),
                      ),
                    ),
                  ),
                  widget.overlayBuilder(context, source),
                  if (_focusPoint != null)
                    _FocusRing(point: _focusPoint!, animation: _focusRing),
                ],
              ),
            );
          },
        );
      },
    );
  }
}

class _FocusRing extends AnimatedWidget {
  final Offset point;

  const _FocusRing({required this.point, required Animation<double> animation})
    : super(listenable: animation);

  @override
  Widget build(BuildContext context) {
    final t = (listenable as Animation<double>).value;
    if (t == 0 || t == 1) return const SizedBox.shrink();
    final scale = 1.3 - 0.3 * Curves.easeOut.transform(min(1, t * 3));
    final opacity = t < 0.7 ? 1.0 : (1 - t) / 0.3;
    return Positioned(
      left: point.dx - 32,
      top: point.dy - 32,
      child: IgnorePointer(
        child: Opacity(
          opacity: opacity,
          child: Transform.scale(
            scale: scale,
            child: Container(
              width: 64,
              height: 64,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
