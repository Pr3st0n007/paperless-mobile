import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/scan_camera_session.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

/// Everything the viewport shows when there is no live preview: startup,
/// permission rationale, permanent denial, missing camera and failures.
/// Image import is always offered so the user is never stuck.
class CameraStatusView extends StatelessWidget {
  final ScanCameraStatus status;
  final VoidCallback onRequestPermission;
  final VoidCallback onOpenSettings;
  final VoidCallback onRetry;
  final VoidCallback? onImport;

  const CameraStatusView({
    super.key,
    required this.status,
    required this.onRequestPermission,
    required this.onOpenSettings,
    required this.onRetry,
    required this.onImport,
  });

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final theme = Theme.of(context);
    if (status == ScanCameraStatus.idle ||
        status == ScanCameraStatus.checkingPermission ||
        status == ScanCameraStatus.initializing) {
      return Center(
        child: Semantics(
          liveRegion: true,
          label: s.scannerStartingCamera,
          child: const CircularProgressIndicator(color: Colors.white),
        ),
      );
    }
    final (icon, title, body, action, onAction) = switch (status) {
      ScanCameraStatus.permissionRequired => (
        Icons.photo_camera_outlined,
        s.scannerPermissionTitle,
        s.scannerPermissionBody,
        s.scannerAllowCamera,
        onRequestPermission,
      ),
      ScanCameraStatus.permissionPermanentlyDenied => (
        Icons.no_photography_outlined,
        s.scannerPermissionTitle,
        s.scannerPermissionDeniedBody,
        s.settings,
        onOpenSettings,
      ),
      ScanCameraStatus.noCamera => (
        Icons.no_photography_outlined,
        s.scannerCameraFailed,
        s.scannerNoCamera,
        null,
        null,
      ),
      _ => (
        Icons.error_outline,
        s.scannerCameraFailed,
        s.scannerCameraFailedBody,
        s.scannerRetry,
        onRetry,
      ),
    };
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 56, color: Colors.white70),
            const SizedBox(height: 16),
            Text(
              title,
              textAlign: TextAlign.center,
              style: theme.textTheme.titleLarge?.copyWith(color: Colors.white),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: Colors.white70,
              ),
            ),
            const SizedBox(height: 24),
            if (action != null)
              FilledButton(onPressed: onAction, child: Text(action)),
            if (onImport != null)
              TextButton.icon(
                onPressed: onImport,
                icon: const Icon(Icons.photo_library_outlined),
                label: Text(s.scannerImportImage),
              ),
          ],
        ),
      ),
    );
  }
}
