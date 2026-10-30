import 'dart:math';

enum ScanFilter { document, color, grayscale, blackAndWhite }

/// Coordinates are relative to the EXIF-oriented source, clockwise from top left.
class ScanEdit {
  final List<Point<double>> corners;
  final ScanFilter filter;
  final int quarterTurns;

  ScanEdit({
    required List<Point<double>> corners,
    this.filter = ScanFilter.document,
    this.quarterTurns = 0,
  }) : corners = List.unmodifiable(corners) {
    if (!isValidCorners(corners) || quarterTurns < 0 || quarterTurns > 3) {
      throw ArgumentError('Invalid scan geometry.');
    }
  }

  static const fullPage = [
    Point(0.0, 0.0),
    Point(1.0, 0.0),
    Point(1.0, 1.0),
    Point(0.0, 1.0),
  ];

  static bool isValidCorners(List<Point<double>> points) {
    if (points.length != 4 ||
        points.any(
          (p) =>
              !p.x.isFinite ||
              !p.y.isFinite ||
              p.x < 0 ||
              p.x > 1 ||
              p.y < 0 ||
              p.y > 1,
        )) {
      return false;
    }
    double area = 0;
    for (var i = 0; i < 4; i++) {
      final a = points[i];
      final b = points[(i + 1) % 4];
      final c = points[(i + 2) % 4];
      if ((b.x - a.x) * (c.y - b.y) - (b.y - a.y) * (c.x - b.x) <= 0.0001) {
        return false;
      }
      if (a.distanceTo(b) < 0.025) return false;
      area += a.x * b.y - b.x * a.y;
    }
    return area / 2 >= 0.02;
  }

  ScanEdit copyWith({
    List<Point<double>>? corners,
    ScanFilter? filter,
    int? quarterTurns,
  }) => ScanEdit(
    corners: corners ?? this.corners,
    filter: filter ?? this.filter,
    quarterTurns: quarterTurns ?? this.quarterTurns,
  );

  Map<String, Object> toJson() => {
    'corners': corners.map((p) => [p.x, p.y]).toList(),
    'filter': filter.name,
    'quarterTurns': quarterTurns,
  };

  factory ScanEdit.fromJson(Map<String, dynamic> json) => ScanEdit(
    corners: (json['corners'] as List)
        .map((p) => Point((p[0] as num).toDouble(), (p[1] as num).toDouble()))
        .toList(),
    filter: ScanFilter.values.byName(json['filter'] as String),
    quarterTurns: json['quarterTurns'] as int,
  );
}
