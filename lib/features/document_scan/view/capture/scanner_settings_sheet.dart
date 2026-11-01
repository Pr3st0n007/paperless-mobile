import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_preferences.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/capture_controls.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

/// Scanner options. Changes apply immediately through [onChanged].
Future<void> showScannerSettingsSheet(
  BuildContext context, {
  required ScanCapturePreferences initial,
  required ValueChanged<ScanCapturePreferences> onChanged,
  required VoidCallback onShowTips,
}) {
  var value = initial;
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        final s = S.of(context)!;
        void update(ScanCapturePreferences next) {
          setState(() => value = next);
          onChanged(next);
        }

        return SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.only(bottom: 16),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: Text(
                    s.scannerSettingsTitle,
                    style: Theme.of(context).textTheme.titleLarge,
                  ),
                ),
                SwitchListTile(
                  title: Text(s.scannerAutoCapture),
                  subtitle: Text(s.scannerAutoCaptureDescription),
                  value: value.autoCapture,
                  onChanged: (v) => update(value.copyWith(autoCapture: v)),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 8, 24, 4),
                  child: Text(
                    s.scannerAutoCaptureSpeed,
                    style: Theme.of(context).textTheme.titleSmall,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 24),
                  child: SegmentedButton<AutoCaptureSpeed>(
                    segments: [
                      for (final speed in AutoCaptureSpeed.values)
                        ButtonSegment(
                          value: speed,
                          label: Text(speedLabel(s, speed)),
                        ),
                    ],
                    selected: {value.speed},
                    onSelectionChanged: value.autoCapture
                        ? (selection) =>
                              update(value.copyWith(speed: selection.single))
                        : null,
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(24, 6, 24, 8),
                  child: Text(
                    s.scannerSpeedHint(
                      (value.speed.holdDuration.inMilliseconds / 1000)
                          .toStringAsFixed(1),
                    ),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
                SwitchListTile(
                  title: Text(s.scannerHapticFeedback),
                  subtitle: Text(s.scannerHapticFeedbackDescription),
                  value: value.haptics,
                  onChanged: (v) => update(value.copyWith(haptics: v)),
                ),
                ListTile(
                  leading: const Icon(Icons.lightbulb_outline),
                  title: Text(s.scannerShowTips),
                  onTap: () {
                    Navigator.pop(context);
                    onShowTips();
                  },
                ),
              ],
            ),
          ),
        );
      },
    ),
  );
}

/// First-run coaching card shown over the viewport until dismissed.
class ScanningTipsCard extends StatelessWidget {
  final VoidCallback onDismiss;

  const ScanningTipsCard({super.key, required this.onDismiss});

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final theme = Theme.of(context);
    Widget tip(IconData icon, String text) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(icon, size: 22, color: theme.colorScheme.primary),
          const SizedBox(width: 12),
          Expanded(child: Text(text, style: theme.textTheme.bodyMedium)),
        ],
      ),
    );
    return Semantics(
      scopesRoute: true,
      namesRoute: true,
      explicitChildNodes: true,
      label: s.scannerTipsTitle,
      child: Card(
        margin: const EdgeInsets.all(20),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(20, 20, 20, 8),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(s.scannerTipsTitle, style: theme.textTheme.titleMedium),
              const SizedBox(height: 8),
              tip(Icons.crop_free, s.scannerTipSurface),
              tip(Icons.fit_screen, s.scannerTipCorners),
              tip(Icons.motion_photos_auto, s.scannerTipSteady),
              tip(Icons.wb_sunny_outlined, s.scannerTipLight),
              Align(
                alignment: Alignment.centerRight,
                child: TextButton(
                  onPressed: onDismiss,
                  child: Text(s.scannerGotIt),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
