import 'dart:math';

class ScanPreviewTransform {
  static List<Point<double>> rotateCorners(
    List<Point<double>> corners,
    int clockwiseDegrees,
  ) {
    if (clockwiseDegrees % 90 != 0) {
      throw ArgumentError.value(clockwiseDegrees, 'clockwiseDegrees');
    }
    final rotation = clockwiseDegrees % 360;
    return List.unmodifiable(
      corners.map(
        (point) => switch (rotation) {
          90 => Point(1 - point.y, point.x),
          180 => Point(1 - point.x, 1 - point.y),
          270 => Point(point.y, 1 - point.x),
          _ => point,
        },
      ),
    );
  }

  /// Maps normalized oriented-frame corners into a BoxFit.cover viewport.
  static List<Point<double>> mapToViewport({
    required List<Point<double>> corners,
    required double sourceWidth,
    required double sourceHeight,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    if (sourceWidth <= 0 ||
        sourceHeight <= 0 ||
        viewportWidth <= 0 ||
        viewportHeight <= 0) {
      throw ArgumentError('Preview and viewport dimensions must be positive.');
    }
    final scale = max(
      viewportWidth / sourceWidth,
      viewportHeight / sourceHeight,
    );
    final displayedWidth = sourceWidth * scale;
    final displayedHeight = sourceHeight * scale;
    final offsetX = (displayedWidth - viewportWidth) / 2;
    final offsetY = (displayedHeight - viewportHeight) / 2;
    return List.unmodifiable(
      corners.map(
        (point) => Point(
          point.x * displayedWidth - offsetX,
          point.y * displayedHeight - offsetY,
        ),
      ),
    );
  }

  /// Inverse of [mapToViewport] for a single point: viewport pixels to
  /// normalized source coordinates, clamped to the visible source.
  static Point<double> viewportToSource({
    required Point<double> point,
    required double sourceWidth,
    required double sourceHeight,
    required double viewportWidth,
    required double viewportHeight,
  }) {
    final scale = max(
      viewportWidth / sourceWidth,
      viewportHeight / sourceHeight,
    );
    final displayedWidth = sourceWidth * scale;
    final displayedHeight = sourceHeight * scale;
    final offsetX = (displayedWidth - viewportWidth) / 2;
    final offsetY = (displayedHeight - viewportHeight) / 2;
    return Point(
      ((point.x + offsetX) / displayedWidth).clamp(0.0, 1.0),
      ((point.y + offsetY) / displayedHeight).clamp(0.0, 1.0),
    );
  }
}
