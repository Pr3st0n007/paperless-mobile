import 'dart:math';

import 'package:camera/camera.dart';
import 'package:flutter/services.dart';

/// Converts camera stream frames into the packed, downsampled RGB input that
/// [DocumentProcessor.analyzeRgbFrame] expects. Nearest-neighbour sampling
/// keeps the per-frame cost on the UI isolate bounded by [longestSide]².
abstract final class CameraFrameConverter {
  static Map<String, Object> toPackedRgb(
    CameraImage frame, {
    int longestSide = 320,
  }) {
    final scale = min(1.0, longestSide / max(frame.width, frame.height));
    final width = max(1, (frame.width * scale).round());
    final height = max(1, (frame.height * scale).round());
    final rgb = Uint8List(width * height * 3);
    final planes = frame.planes;
    switch (frame.format.group) {
      case ImageFormatGroup.yuv420 when planes.length >= 3:
        _fromYuv420(frame, planes, scale, width, height, rgb);
      case ImageFormatGroup.bgra8888 when planes.isNotEmpty:
        _fromBgra(frame, planes.first, scale, width, height, rgb);
      default:
        throw FormatException(
          'Unsupported camera format: ${frame.format.group}',
        );
    }
    return {'width': width, 'height': height, 'rgb': rgb};
  }

  static void _fromYuv420(
    CameraImage frame,
    List<Plane> planes,
    double scale,
    int width,
    int height,
    Uint8List rgb,
  ) {
    final yPlane = planes[0];
    final uPlane = planes[1];
    final vPlane = planes[2];
    final yBytes = yPlane.bytes;
    final uBytes = uPlane.bytes;
    final vBytes = vPlane.bytes;
    final uPixelStride = uPlane.bytesPerPixel ?? 1;
    final vPixelStride = vPlane.bytesPerPixel ?? 1;
    var offset = 0;
    for (var y = 0; y < height; y++) {
      final sourceY = min(frame.height - 1, (y / scale).floor());
      final yRow = sourceY * yPlane.bytesPerRow;
      final uRow = (sourceY ~/ 2) * uPlane.bytesPerRow;
      final vRow = (sourceY ~/ 2) * vPlane.bytesPerRow;
      for (var x = 0; x < width; x++) {
        final sourceX = min(frame.width - 1, (x / scale).floor());
        final c = max(0, yBytes[yRow + sourceX] - 16);
        final u = uBytes[uRow + (sourceX ~/ 2) * uPixelStride] - 128;
        final v = vBytes[vRow + (sourceX ~/ 2) * vPixelStride] - 128;
        rgb[offset++] = _clamp((298 * c + 409 * v + 128) >> 8);
        rgb[offset++] = _clamp((298 * c - 100 * u - 208 * v + 128) >> 8);
        rgb[offset++] = _clamp((298 * c + 516 * u + 128) >> 8);
      }
    }
  }

  static void _fromBgra(
    CameraImage frame,
    Plane plane,
    double scale,
    int width,
    int height,
    Uint8List rgb,
  ) {
    final bytes = plane.bytes;
    var offset = 0;
    for (var y = 0; y < height; y++) {
      final row = min(frame.height - 1, (y / scale).floor()) * plane.bytesPerRow;
      for (var x = 0; x < width; x++) {
        final input = row + min(frame.width - 1, (x / scale).floor()) * 4;
        rgb[offset++] = bytes[input + 2];
        rgb[offset++] = bytes[input + 1];
        rgb[offset++] = bytes[input];
      }
    }
  }

  static int _clamp(int value) => value < 0 ? 0 : (value > 255 ? 255 : value);

  /// Clockwise rotation from sensor frame to the upright preview.
  static int rotationFor(
    CameraDescription camera,
    DeviceOrientation deviceOrientation,
  ) {
    final device = switch (deviceOrientation) {
      DeviceOrientation.portraitUp => 0,
      DeviceOrientation.landscapeLeft => 90,
      DeviceOrientation.portraitDown => 180,
      DeviceOrientation.landscapeRight => 270,
    };
    return (camera.sensorOrientation - device + 360) % 360;
  }
}
