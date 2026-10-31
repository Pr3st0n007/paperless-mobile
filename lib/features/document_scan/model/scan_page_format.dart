enum ScanPageFormatKind { auto, a4, letter, custom }

class ScanPageFormat {
  final ScanPageFormatKind kind;
  final double widthMm;
  final double heightMm;

  const ScanPageFormat._(this.kind, this.widthMm, this.heightMm);

  static const auto = ScanPageFormat._(ScanPageFormatKind.auto, 0, 0);
  static const a4 = ScanPageFormat._(ScanPageFormatKind.a4, 210, 297);
  static const letter = ScanPageFormat._(ScanPageFormatKind.letter, 215.9, 279.4);

  factory ScanPageFormat.custom(double widthMm, double heightMm) {
    if (!widthMm.isFinite ||
        !heightMm.isFinite ||
        widthMm <= 0 ||
        heightMm <= 0) {
      throw ArgumentError('Custom page dimensions must be positive.');
    }
    return ScanPageFormat._(ScanPageFormatKind.custom, widthMm, heightMm);
  }

  double get aspectRatio => widthMm / heightMm;

  /// Returns width and height in millimetres, oriented to match the content.
  (double, double) dimensionsFor(double contentAspectRatio) {
    if (kind == ScanPageFormatKind.auto) {
      return contentAspectRatio >= 1
          ? (297.0, 297.0 / contentAspectRatio)
          : (297.0 * contentAspectRatio, 297.0);
    }
    final landscape = contentAspectRatio >= 1;
    final width = widthMm < heightMm ? heightMm : widthMm;
    final height = widthMm < heightMm ? widthMm : heightMm;
    return landscape ? (width, height) : (height, width);
  }

  Map<String, Object> toJson() => {
    'kind': kind.name,
    if (kind == ScanPageFormatKind.custom) ...{
      'widthMm': widthMm,
      'heightMm': heightMm,
    },
  };

  factory ScanPageFormat.fromJson(Map<String, dynamic> json) {
    final kind = ScanPageFormatKind.values.byName(json['kind'] as String);
    return switch (kind) {
      ScanPageFormatKind.auto => auto,
      ScanPageFormatKind.a4 => a4,
      ScanPageFormatKind.letter => letter,
      ScanPageFormatKind.custom => ScanPageFormat.custom(
        (json['widthMm'] as num).toDouble(),
        (json['heightMm'] as num).toDouble(),
      ),
    };
  }

  @override
  bool operator ==(Object other) =>
      other is ScanPageFormat &&
      other.kind == kind &&
      other.widthMm == widthMm &&
      other.heightMm == heightMm;

  @override
  int get hashCode => Object.hash(kind, widthMm, heightMm);
}
