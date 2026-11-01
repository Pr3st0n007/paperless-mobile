import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

/// Camera-style shutter with an auto-capture countdown ring.
class ShutterButton extends StatelessWidget {
  final VoidCallback? onPressed;
  final Animation<double> countdown;
  final bool busy;
  final bool retaking;

  const ShutterButton({
    super.key,
    required this.onPressed,
    required this.countdown,
    this.busy = false,
    this.retaking = false,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final enabled = onPressed != null;
    return Semantics(
      button: true,
      enabled: enabled,
      label: retaking ? s.scannerRetakeCaptured : s.scannerShutter,
      excludeSemantics: true,
      child: SizedBox.square(
        dimension: 80,
        child: Stack(
          alignment: Alignment.center,
          children: [
            Container(
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                border: Border.all(
                  color: Colors.white.withValues(alpha: enabled ? 1 : 0.4),
                  width: 4,
                ),
              ),
            ),
            AnimatedBuilder(
              animation: countdown,
              builder: (context, _) => countdown.value == 0
                  ? const SizedBox.shrink()
                  : SizedBox.square(
                      dimension: 80,
                      child: CircularProgressIndicator(
                        value: countdown.value,
                        strokeWidth: 4,
                        color: scheme.primary,
                      ),
                    ),
            ),
            Material(
              color: enabled
                  ? Colors.white
                  : Colors.white.withValues(alpha: 0.4),
              shape: const CircleBorder(),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: onPressed,
                child: SizedBox.square(
                  dimension: 62,
                  child: busy
                      ? const Padding(
                          padding: EdgeInsets.all(18),
                          child: CircularProgressIndicator(
                            strokeWidth: 3,
                            color: Colors.black54,
                          ),
                        )
                      : Icon(
                          retaking ? Icons.refresh : Icons.camera_alt,
                          size: 30,
                          color: Colors.black87,
                        ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Compact auto/manual toggle showing the active speed preset.
class AutoCaptureToggle extends StatelessWidget {
  final bool enabled;
  final AutoCaptureSpeed speed;
  final ValueChanged<bool>? onChanged;

  const AutoCaptureToggle({
    super.key,
    required this.enabled,
    required this.speed,
    required this.onChanged,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    final foreground = enabled ? scheme.onPrimaryContainer : Colors.white;
    return Semantics(
      toggled: enabled,
      label: s.scannerAutoCapture,
      value: enabled ? speedLabel(s, speed) : null,
      excludeSemantics: true,
      child: Material(
        color: enabled ? scheme.primaryContainer : Colors.white12,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onChanged == null ? null : () => onChanged!(!enabled),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 48, minWidth: 88),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        enabled ? Icons.motion_photos_auto : Icons.touch_app,
                        size: 18,
                        color: foreground,
                      ),
                      const SizedBox(width: 6),
                      Text(
                        enabled ? s.scannerModeAuto : s.scannerModeManual,
                        style: Theme.of(context).textTheme.labelLarge
                            ?.copyWith(color: foreground),
                      ),
                    ],
                  ),
                  if (enabled)
                    Text(
                      speedLabel(s, speed),
                      style: Theme.of(context).textTheme.labelSmall
                          ?.copyWith(color: foreground),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

String speedLabel(S s, AutoCaptureSpeed speed) => switch (speed) {
  AutoCaptureSpeed.relaxed => s.scannerSpeedRelaxed,
  AutoCaptureSpeed.balanced => s.scannerSpeedBalanced,
  AutoCaptureSpeed.fast => s.scannerSpeedFast,
};

String guidanceText(S s, CaptureGuidance guidance) => switch (guidance) {
  CaptureGuidance.searching => s.scannerGuidanceSearching,
  CaptureGuidance.moveCloser => s.scannerGuidanceMoveCloser,
  CaptureGuidance.tooDark => s.scannerGuidanceTooDark,
  CaptureGuidance.tooBright => s.scannerGuidanceTooBright,
  CaptureGuidance.blurry => s.scannerGuidanceBlurry,
  CaptureGuidance.holdSteady => s.scannerGuidanceHoldSteady,
  CaptureGuidance.holding => s.scannerGuidanceHolding,
  CaptureGuidance.ready => s.scannerGuidanceReady,
  CaptureGuidance.capturing => s.scannerGuidanceCapturing,
  CaptureGuidance.nextPage => s.scannerGuidanceNextPage,
};
