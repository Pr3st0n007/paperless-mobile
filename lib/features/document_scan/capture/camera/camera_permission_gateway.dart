import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:permission_handler/permission_handler.dart';

enum CameraPermissionStatus { granted, denied, permanentlyDenied }

abstract interface class CameraPermissionGateway {
  Future<CameraPermissionStatus> status();
  Future<CameraPermissionStatus> request();
  Future<void> openSettings();
}

/// Uses permission_handler on Android so the app can explain and recover from
/// denial before touching the camera. Elsewhere the camera plugin requests
/// access itself during initialization.
class PlatformCameraPermissionGateway implements CameraPermissionGateway {
  const PlatformCameraPermissionGateway();

  bool get _managed => defaultTargetPlatform == TargetPlatform.android;

  @override
  Future<CameraPermissionStatus> status() =>
      _guard(() => Permission.camera.status);

  @override
  Future<CameraPermissionStatus> request() =>
      _guard(() => Permission.camera.request());

  @override
  Future<void> openSettings() => openAppSettings();

  Future<CameraPermissionStatus> _guard(
    Future<PermissionStatus> Function() query,
  ) async {
    if (!_managed) return CameraPermissionStatus.granted;
    try {
      final result = await query();
      if (result.isGranted || result.isLimited) {
        return CameraPermissionStatus.granted;
      }
      if (result.isPermanentlyDenied || result.isRestricted) {
        return CameraPermissionStatus.permanentlyDenied;
      }
      return CameraPermissionStatus.denied;
    } on MissingPluginException {
      // Let the camera plugin surface access errors instead.
      return CameraPermissionStatus.granted;
    }
  }
}
