import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/capture_controls.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

/// Single-line status pill above the viewport.
///
/// Messages are held for [_minimumDisplay] so they stay readable when the
/// detector flickers, and announced to screen readers only after they have
/// persisted for [_announceAfter] to avoid flooding TalkBack.
class GuidanceChip extends StatefulWidget {
  final CaptureGuidance guidance;

  /// Overrides the guidance text (e.g. live detection unavailable).
  final String? message;

  const GuidanceChip({super.key, required this.guidance, this.message});

  @override
  State<GuidanceChip> createState() => _GuidanceChipState();
}

class _GuidanceChipState extends State<GuidanceChip> {
  static const _minimumDisplay = Duration(milliseconds: 700);
  static const _announceAfter = Duration(milliseconds: 1200);
  static const _urgent = {CaptureGuidance.capturing, CaptureGuidance.nextPage};

  late CaptureGuidance _shown = widget.guidance;
  DateTime _shownAt = DateTime.now();
  Timer? _pending;
  Timer? _announce;
  CaptureGuidance? _announced;

  @override
  void initState() {
    super.initState();
    _scheduleAnnouncement();
  }

  @override
  void didUpdateWidget(GuidanceChip oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.guidance == _shown) {
      _pending?.cancel();
      return;
    }
    final age = DateTime.now().difference(_shownAt);
    _pending?.cancel();
    if (age >= _minimumDisplay || _urgent.contains(widget.guidance)) {
      _show(widget.guidance);
    } else {
      _pending = Timer(_minimumDisplay - age, () => _show(widget.guidance));
    }
  }

  void _show(CaptureGuidance guidance) {
    if (!mounted) return;
    setState(() {
      _shown = guidance;
      _shownAt = DateTime.now();
    });
    _scheduleAnnouncement();
  }

  void _scheduleAnnouncement() {
    _announce?.cancel();
    _announce = Timer(_announceAfter, () {
      if (!mounted || _announced == _shown || widget.message != null) return;
      _announced = _shown;
      SemanticsService.announce(
        guidanceText(S.of(context)!, _shown),
        Directionality.of(context),
      );
    });
  }

  @override
  void dispose() {
    _pending?.cancel();
    _announce?.cancel();
    super.dispose();
  }

  IconData get _icon => switch (_shown) {
    CaptureGuidance.searching => Icons.document_scanner_outlined,
    CaptureGuidance.moveCloser => Icons.zoom_in,
    CaptureGuidance.tooDark => Icons.wb_incandescent_outlined,
    CaptureGuidance.tooBright => Icons.wb_sunny_outlined,
    CaptureGuidance.blurry || CaptureGuidance.holdSteady => Icons.pan_tool_alt,
    CaptureGuidance.holding => Icons.hourglass_top,
    CaptureGuidance.ready || CaptureGuidance.capturing => Icons.check_circle,
    CaptureGuidance.nextPage => Icons.library_add_check_outlined,
  };

  @override
  Widget build(BuildContext context) {
    final text = widget.message ?? guidanceText(S.of(context)!, _shown);
    final reduceMotion = MediaQuery.of(context).disableAnimations;
    return AnimatedSwitcher(
      duration: reduceMotion ? Duration.zero : const Duration(milliseconds: 200),
      child: DecoratedBox(
        key: ValueKey(text),
        decoration: ShapeDecoration(
          color: Colors.black.withValues(alpha: 0.6),
          shape: const StadiumBorder(),
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(
                widget.message != null ? Icons.info_outline : _icon,
                size: 18,
                color: Colors.white,
              ),
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  text,
                  textAlign: TextAlign.center,
                  style: Theme.of(
                    context,
                  ).textTheme.bodyMedium?.copyWith(color: Colors.white),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
