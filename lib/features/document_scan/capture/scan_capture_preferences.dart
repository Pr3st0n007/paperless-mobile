import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_tuning.dart';
import 'package:shared_preferences/shared_preferences.dart';

@immutable
class ScanCapturePreferences {
  /// Off by default: the user opts in once and the choice is remembered.
  final bool autoCapture;
  final AutoCaptureSpeed speed;
  final bool haptics;
  final bool tipsSeen;

  const ScanCapturePreferences({
    this.autoCapture = false,
    this.speed = AutoCaptureSpeed.defaultSpeed,
    this.haptics = true,
    this.tipsSeen = false,
  });

  ScanCapturePreferences copyWith({
    bool? autoCapture,
    AutoCaptureSpeed? speed,
    bool? haptics,
    bool? tipsSeen,
  }) => ScanCapturePreferences(
    autoCapture: autoCapture ?? this.autoCapture,
    speed: speed ?? this.speed,
    haptics: haptics ?? this.haptics,
    tipsSeen: tipsSeen ?? this.tipsSeen,
  );
}

class ScanCapturePreferencesStore {
  static const _autoCapture = 'scanner.autoCapture';
  static const _speed = 'scanner.autoCaptureSpeed';
  static const _haptics = 'scanner.haptics';
  static const _tipsSeen = 'scanner.tipsSeen';

  const ScanCapturePreferencesStore();

  Future<ScanCapturePreferences> load() async {
    final prefs = await SharedPreferences.getInstance();
    const defaults = ScanCapturePreferences();
    return ScanCapturePreferences(
      autoCapture: prefs.getBool(_autoCapture) ?? defaults.autoCapture,
      speed: AutoCaptureSpeed.values.asNameMap()[prefs.getString(_speed)] ??
          defaults.speed,
      haptics: prefs.getBool(_haptics) ?? defaults.haptics,
      tipsSeen: prefs.getBool(_tipsSeen) ?? defaults.tipsSeen,
    );
  }

  Future<void> save(ScanCapturePreferences value) async {
    final prefs = await SharedPreferences.getInstance();
    await Future.wait([
      prefs.setBool(_autoCapture, value.autoCapture),
      prefs.setString(_speed, value.speed.name),
      prefs.setBool(_haptics, value.haptics),
      prefs.setBool(_tipsSeen, value.tipsSeen),
    ]);
  }
}
