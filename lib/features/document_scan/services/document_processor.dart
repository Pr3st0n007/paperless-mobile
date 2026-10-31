import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';

class ScanAnalysis {
  final Uint8List preview;
  final int width;
  final int height;
  final List<Point<double>>? detectedCorners;

  const ScanAnalysis(
    this.preview,
    this.width,
    this.height,
    this.detectedCorners,
  );
}

class ScanRenderRequest {
  final Uint8List bytes;
  final ScanEdit edit;
  final bool preview;

  const ScanRenderRequest(this.bytes, this.edit, {this.preview = false});
}

class ScanQualityAssessment {
  final double edgeSharpness;
  final double underexposedFraction;
  final double clippedFraction;
  final double glareLikeFraction;

  const ScanQualityAssessment({
    required this.edgeSharpness,
    required this.underexposedFraction,
    required this.clippedFraction,
    required this.glareLikeFraction,
  });

  bool get isAcceptable =>
      edgeSharpness >= 5 &&
      underexposedFraction <= 0.55 &&
      clippedFraction <= 0.90;
}

class ScanFrameAnalysis {
  final List<Point<double>>? detectedCorners;
  final ScanQualityAssessment quality;
  final Uint8List pageFingerprint;

  const ScanFrameAnalysis(
    this.detectedCorners,
    this.quality,
    this.pageFingerprint,
  );
}

bool hasClearPageChange(
  Uint8List previous,
  Uint8List current, {
  double hammingThreshold = 0.22,
}) {
  if (previous.length != current.length || previous.isEmpty) return false;
  var differences = 0;
  for (var i = 0; i < previous.length; i++) {
    if (previous[i] != current[i]) differences++;
  }
  return differences / previous.length >= hammingThreshold;
}

class ScanAutoCaptureGate {
  bool _enabled = false;
  bool _armed = true;
  bool _waitingForNextPage = false;
  int _missingFrames = 0;
  List<Point<double>>? _capturedCorners;
  Uint8List? _capturedFingerprint;

  bool get enabled => _enabled;

  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (enabled && !_waitingForNextPage) _armed = true;
  }

  bool shouldCapture({
    required bool stable,
    required bool qualityAcceptable,
    required bool retaking,
  }) {
    if (!_enabled ||
        !_armed ||
        !stable ||
        !qualityAcceptable ||
        retaking) {
      return false;
    }
    _armed = false;
    return true;
  }

  void pageCaptured({
    required List<Point<double>>? corners,
    required Uint8List? fingerprint,
  }) {
    _armed = false;
    _waitingForNextPage = true;
    _missingFrames = 0;
    _capturedCorners = corners == null ? null : List.unmodifiable(corners);
    _capturedFingerprint = fingerprint == null
        ? null
        : Uint8List.fromList(fingerprint);
  }

  bool observe({
    required List<Point<double>>? corners,
    required Uint8List fingerprint,
  }) {
    if (!_waitingForNextPage) return false;
    if (corners == null) {
      _missingFrames++;
      if (_missingFrames < 5) return false;
      _rearm();
      return true;
    }
    _missingFrames = 0;
    final captured = _capturedCorners;
    if (captured != null &&
        (_maxCornerMovement(corners, captured) > 0.18 ||
            hasClearPageChange(
              _capturedFingerprint ?? Uint8List(0),
              fingerprint,
            ))) {
      _rearm();
      return true;
    }
    return false;
  }

  void _rearm() {
    _waitingForNextPage = false;
    _armed = true;
    _capturedCorners = null;
    _capturedFingerprint = null;
  }

  double _maxCornerMovement(
    List<Point<double>> a,
    List<Point<double>> b,
  ) {
    var movement = 0.0;
    for (var i = 0; i < 4; i++) {
      movement = max(movement, a[i].distanceTo(b[i]));
    }
    return movement;
  }
}

enum ScanBoundaryStatus { uncertain, stable }

class ScanBoundaryUpdate {
  final ScanBoundaryStatus status;
  final List<Point<double>>? corners;
  final bool transitionedToStable;
  final bool transitionedToUnstable;

  const ScanBoundaryUpdate({
    required this.status,
    required this.corners,
    required this.transitionedToStable,
    required this.transitionedToUnstable,
  });
}

/// Four consecutive geometrically valid frames with limited corner movement
/// are required for stable feedback. A missed or jumping result clears it.
class ScanBoundaryStability {
  final int requiredFrames;
  final double maximumCornerMovement;
  List<Point<double>>? _previous;
  int _consecutive = 0;
  bool _stable = false;

  ScanBoundaryStability({
    this.requiredFrames = 4,
    this.maximumCornerMovement = 0.035,
  }) : assert(requiredFrames > 0),
       assert(maximumCornerMovement > 0);

  ScanBoundaryUpdate update(List<Point<double>>? corners) {
    final wasStable = _stable;
    if (corners == null || !ScanEdit.isValidCorners(corners)) {
      _previous = null;
      _consecutive = 0;
      _stable = false;
    } else {
      final previous = _previous;
      final moved = previous == null ||
          List.generate(
            4,
            (i) => corners[i].distanceTo(previous[i]),
          ).any((distance) => distance > maximumCornerMovement);
      _consecutive = moved ? 1 : _consecutive + 1;
      _previous = List.unmodifiable(corners);
      _stable = _consecutive >= requiredFrames;
    }
    return ScanBoundaryUpdate(
      status: _stable
          ? ScanBoundaryStatus.stable
          : ScanBoundaryStatus.uncertain,
      corners: corners == null ? null : List.unmodifiable(corners),
      transitionedToStable: !wasStable && _stable,
      transitionedToUnstable: wasStable && !_stable,
    );
  }
}

/// Runs in an isolate; no camera images or document contents leave the device.
class DocumentProcessor {
  static img.Image _decode(Uint8List bytes) {
    if (bytes.length < 8) {
      throw const FormatException('Unsupported scan image.');
    }
    final image = img.decodeImage(bytes);
    if (image == null) throw const FormatException('Unsupported scan image.');
    return img.bakeOrientation(image);
  }

  static ScanAnalysis analyze(Uint8List bytes) {
    final source = _decode(bytes);
    final preview = _limitSize(source, 1200);
    return ScanAnalysis(
      Uint8List.fromList(img.encodeJpg(preview, quality: 90)),
      preview.width,
      preview.height,
      detectCorners(source),
    );
  }

  /// Local preview-quality heuristics. They gate blur/exposure, but do not
  /// promise legibility; the glare estimate is only a clipped-highlight proxy.
  static ScanQualityAssessment assessQuality(Uint8List bytes) {
    return _assessQualityImage(_limitSize(_decode(bytes), 320));
  }

  /// Input is a downsampled, packed RGB frame prepared from CameraImage planes.
  static ScanFrameAnalysis analyzeRgbFrame(Map<String, Object> frame) {
    final width = frame['width']! as int;
    final height = frame['height']! as int;
    final rgb = frame['rgb']! as Uint8List;
    if (width < 16 || height < 16 || rgb.length != width * height * 3) {
      throw const FormatException('Unsupported camera frame.');
    }
    final image = img.Image(width: width, height: height);
    for (final p in image) {
      final offset = (p.y * width + p.x) * 3;
      p.setRgb(rgb[offset], rgb[offset + 1], rgb[offset + 2]);
    }
    final corners = detectCorners(image);
    return ScanFrameAnalysis(
      corners,
      _assessQualityImage(image, corners),
      _pageFingerprint(image, corners),
    );
  }

  static Uint8List _pageFingerprint(
    img.Image image,
    List<Point<double>>? corners,
  ) {
    if (corners == null) return Uint8List(0);
    const side = 16;
    final values = Uint8List(side * side);
    var sum = 0;
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final u = (x + 0.5) / side;
        final v = (y + 0.5) / side;
        final top = Point(
          corners[0].x * (1 - u) + corners[1].x * u,
          corners[0].y * (1 - u) + corners[1].y * u,
        );
        final bottom = Point(
          corners[3].x * (1 - u) + corners[2].x * u,
          corners[3].y * (1 - u) + corners[2].y * u,
        );
        final point = Point(
          top.x * (1 - v) + bottom.x * v,
          top.y * (1 - v) + bottom.y * v,
        );
        final pixel = image.getPixel(
          (point.x * (image.width - 1))
              .round()
              .clamp(0, image.width - 1)
              .toInt(),
          (point.y * (image.height - 1))
              .round()
              .clamp(0, image.height - 1)
              .toInt(),
        );
        final value = _luma(pixel);
        values[y * side + x] = value;
        sum += value;
      }
    }
    final mean = sum / values.length;
    return Uint8List.fromList(
      values.map((value) => value < mean ? 0 : 1).toList(),
    );
  }

  static img.Image _sampleQuadrilateral(
    img.Image image,
    List<Point<double>> corners,
    int side,
  ) {
    final sample = img.Image(width: side, height: side);
    for (var y = 0; y < side; y++) {
      for (var x = 0; x < side; x++) {
        final u = (x + 0.5) / side;
        final v = (y + 0.5) / side;
        final top = Point(
          corners[0].x * (1 - u) + corners[1].x * u,
          corners[0].y * (1 - u) + corners[1].y * u,
        );
        final bottom = Point(
          corners[3].x * (1 - u) + corners[2].x * u,
          corners[3].y * (1 - u) + corners[2].y * u,
        );
        final point = Point(
          top.x * (1 - v) + bottom.x * v,
          top.y * (1 - v) + bottom.y * v,
        );
        sample.setPixel(
          x,
          y,
          image.getPixel(
            (point.x * (image.width - 1))
                .round()
                .clamp(0, image.width - 1)
                .toInt(),
            (point.y * (image.height - 1))
                .round()
                .clamp(0, image.height - 1)
                .toInt(),
          ),
        );
      }
    }
    return sample;
  }

  static ScanQualityAssessment _assessQualityImage(
    img.Image source, [
    List<Point<double>>? corners,
  ]) {
    final image = corners == null
        ? _limitSize(source, 128)
        : _sampleQuadrilateral(source, corners, 128);
    var gradients = 0.0;
    var gradientSamples = 0;
    var underexposed = 0;
    var clipped = 0;
    var glareLike = 0;
    final count = image.width * image.height;
    final values = Uint8List(count);
    for (final p in image) {
      final value = _luma(p);
      values[p.y * image.width + p.x] = value;
      if (value < 35) underexposed++;
      if (value > 250) clipped++;
    }
    for (var y = 1; y < image.height - 1; y++) {
      for (var x = 1; x < image.width - 1; x++) {
        final index = y * image.width + x;
        final center = values[index];
        final horizontal = (center - values[index + 1]).abs();
        final vertical = (center - values[index + image.width]).abs();
        gradients += horizontal + vertical;
        gradientSamples += 2;
        if (center > 250 && horizontal < 3 && vertical < 3) glareLike++;
      }
    }
    return ScanQualityAssessment(
      edgeSharpness: gradientSamples == 0 ? 0 : gradients / gradientSamples,
      underexposedFraction: underexposed / count,
      clippedFraction: clipped / count,
      glareLikeFraction: glareLike / count,
    );
  }

  static img.Image _limitSize(img.Image image, int longestSide) {
    final scale = longestSide / max(image.width, image.height);
    if (scale >= 1) return image;
    return img.copyResize(
      image,
      width: max(1, (image.width * scale).round()),
      height: max(1, (image.height * scale).round()),
      interpolation: img.Interpolation.average,
    );
  }

  /// Finds a large, light, low-chroma connected region rather than text edges.
  /// Uncertain detections return null so the editor never silently crops a page.
  static List<Point<double>>? detectCorners(img.Image source) {
    final image = _limitSize(source, 320);
    final width = image.width;
    final height = image.height;
    if (width < 16 || height < 16) return null;
    final count = width * height;
    final luminance = Uint8List(count);
    final histogram = List<int>.filled(256, 0);
    for (final p in image) {
      final value = _luma(p);
      luminance[p.y * width + p.x] = value;
      histogram[value]++;
    }
    final threshold = _otsu(histogram, count).clamp(100, 220);
    final mask = Uint8List(count);
    for (final p in image) {
      if (luminance[p.y * width + p.x] > threshold &&
          max(p.r, max(p.g, p.b)) - min(p.r, min(p.g, p.b)) < 85) {
        mask[p.y * width + p.x] = 1;
      }
    }
    final queue = Int32List(count);
    List<Point<double>>? best;
    double bestScore = 0;
    for (var start = 0; start < count; start++) {
      if (mask[start] == 0) continue;
      var head = 0;
      var tail = 1;
      queue[0] = start;
      mask[start] = 0;
      final boundary = <Point<double>>[];
      while (head < tail) {
        final index = queue[head++];
        final x = index % width;
        final y = index ~/ width;
        var edge = false;
        for (final (nx, ny) in [
          (x - 1, y),
          (x + 1, y),
          (x, y - 1),
          (x, y + 1),
        ]) {
          if (nx < 0 || ny < 0 || nx >= width || ny >= height) {
            edge = true;
            continue;
          }
          final next = ny * width + nx;
          if (luminance[next] <= threshold) edge = true;
          if (mask[next] == 1) {
            mask[next] = 0;
            queue[tail++] = next;
          }
        }
        if (edge) boundary.add(Point(x.toDouble(), y.toDouble()));
      }
      if (tail < count * 0.12 || boundary.length < 4) continue;
      final hull = _convexHull(boundary);
      while (hull.length > 4) {
        var smallest = double.infinity;
        var remove = 0;
        for (var i = 0; i < hull.length; i++) {
          final area = _cross(
            hull[(i + hull.length - 1) % hull.length],
            hull[i],
            hull[(i + 1) % hull.length],
          ).abs();
          if (area < smallest) {
            smallest = area;
            remove = i;
          }
        }
        hull.removeAt(remove);
      }
      if (hull.length != 4) continue;
      var first = 0;
      for (var i = 1; i < 4; i++) {
        if (hull[i].x + hull[i].y < hull[first].x + hull[first].y) first = i;
      }
      final corners = List.generate(
        4,
        (i) => Point(
          hull[(first + i) % 4].x / (width - 1),
          hull[(first + i) % 4].y / (height - 1),
        ),
      );
      if (!ScanEdit.isValidCorners(corners)) continue;
      // A region touching the whole frame is usually a white desk, not a page.
      final touching = corners
          .where((p) => p.x < .015 || p.x > .985 || p.y < .015 || p.y > .985)
          .length;
      if (touching > 2) continue;
      double area = 0;
      for (var i = 0; i < 4; i++) {
        final a = hull[i];
        final b = hull[(i + 1) % 4];
        area += a.x * b.y - b.x * a.y;
      }
      area = area.abs() / 2;
      if (tail / area < 0.65) continue;
      final score = tail.toDouble() * (tail / area);
      if (score > bestScore) {
        bestScore = score;
        best = corners;
      }
    }
    return best;
  }

  static double _cross(Point<double> a, Point<double> b, Point<double> c) =>
      (b.x - a.x) * (c.y - a.y) - (b.y - a.y) * (c.x - a.x);

  static List<Point<double>> _convexHull(List<Point<double>> points) {
    points.sort((a, b) {
      final x = a.x.compareTo(b.x);
      return x == 0 ? a.y.compareTo(b.y) : x;
    });
    final lower = <Point<double>>[];
    final upper = <Point<double>>[];
    for (final p in points) {
      while (lower.length >= 2 &&
          _cross(lower[lower.length - 2], lower.last, p) <= 0) {
        lower.removeLast();
      }
      lower.add(p);
    }
    for (final p in points.reversed) {
      while (upper.length >= 2 &&
          _cross(upper[upper.length - 2], upper.last, p) <= 0) {
        upper.removeLast();
      }
      upper.add(p);
    }
    return [...lower.take(lower.length - 1), ...upper.take(upper.length - 1)];
  }

  static int _otsu(List<int> histogram, int count) {
    double sum = 0;
    for (var i = 0; i < 256; i++) {
      sum += i * histogram[i];
    }
    var backgroundCount = 0;
    double backgroundSum = 0;
    double variance = -1;
    var threshold = 127;
    for (var i = 0; i < 256; i++) {
      backgroundCount += histogram[i];
      if (backgroundCount == 0) continue;
      final foregroundCount = count - backgroundCount;
      if (foregroundCount == 0) break;
      backgroundSum += i * histogram[i];
      final difference =
          backgroundSum / backgroundCount -
          (sum - backgroundSum) / foregroundCount;
      final candidate =
          backgroundCount * foregroundCount * difference * difference;
      if (candidate > variance) {
        variance = candidate;
        threshold = i;
      }
    }
    return threshold;
  }

  static Uint8List render(ScanRenderRequest request) {
    final source = _limitSize(
      _decode(request.bytes),
      request.preview ? 1200 : 4500,
    );
    final edit = request.edit;
    final points = edit.corners
        .map((p) => Point(p.x * (source.width - 1), p.y * (source.height - 1)))
        .toList();
    final width =
        (points[0].distanceTo(points[1]) + points[3].distanceTo(points[2])) / 2;
    final height =
        (points[0].distanceTo(points[3]) + points[1].distanceTo(points[2])) / 2;
    final naturalRatio = width / height;
    final rotatedRatio = edit.quarterTurns.isEven
        ? naturalRatio
        : 1 / naturalRatio;
    final pageDimensions = edit.pageFormat.dimensionsFor(rotatedRatio);
    final pageRatio = pageDimensions.$1 / pageDimensions.$2;
    final rasterRatio = edit.quarterTurns.isEven ? pageRatio : 1 / pageRatio;
    final maxLongSide = request.preview ? 1200 : 3508;
    // Keep source detail without upscaling; cap at approximately 300 dpi.
    final availableLongSide = max(width, height);
    final longSide = min(maxLongSide, availableLongSide).floor().clamp(2, 3508);
    final canvasWidth = rasterRatio >= 1
        ? longSide
        : max(2, (longSide * rasterRatio).round());
    final canvasHeight = rasterRatio >= 1
        ? max(2, (longSide / rasterRatio).round())
        : longSide;
    final fitRatio = naturalRatio;
    final contentWidth = fitRatio > rasterRatio
        ? canvasWidth.toDouble()
        : canvasHeight * fitRatio;
    final contentHeight = fitRatio > rasterRatio
        ? canvasWidth / fitRatio
        : canvasHeight.toDouble();
    final offsetX = (canvasWidth - contentWidth) / 2;
    final offsetY = (canvasHeight - contentHeight) / 2;
    var result = img.Image(width: canvasWidth, height: canvasHeight);
    img.fill(result, color: img.ColorRgb8(255, 255, 255));
    final transform = _homography(points);
    for (var y = 0; y < result.height; y++) {
      if (y < offsetY || y >= offsetY + contentHeight) continue;
      final v = ((y - offsetY) / max(1, contentHeight - 1)).clamp(0, 1);
      for (var x = 0; x < result.width; x++) {
        if (x < offsetX || x >= offsetX + contentWidth) continue;
        final u = ((x - offsetX) / max(1, contentWidth - 1)).clamp(0, 1);
        final divisor = transform[6] * u + transform[7] * v + 1;
        final sx =
            (transform[0] * u + transform[1] * v + transform[2]) / divisor;
        final sy =
            (transform[3] * u + transform[4] * v + transform[5]) / divisor;
        result.setPixel(
          x,
          y,
          source.getPixelInterpolate(
            sx.clamp(0, source.width - 1).toDouble(),
            sy.clamp(0, source.height - 1).toDouble(),
            interpolation: img.Interpolation.linear,
          ),
        );
      }
    }
    if (edit.filter != ScanFilter.color) _enhance(result, edit.filter);
    if (edit.quarterTurns != 0) {
      result = img.copyRotate(result, angle: edit.quarterTurns * 90);
    }
    return Uint8List.fromList(img.encodeJpg(result, quality: 92));
  }

  /// Unit square to source quadrilateral (projective, not a bilinear warp).
  static List<double> _homography(List<Point<double>> p) {
    final dx1 = p[1].x - p[2].x;
    final dx2 = p[3].x - p[2].x;
    final dx3 = p[0].x - p[1].x + p[2].x - p[3].x;
    final dy1 = p[1].y - p[2].y;
    final dy2 = p[3].y - p[2].y;
    final dy3 = p[0].y - p[1].y + p[2].y - p[3].y;
    final determinant = dx1 * dy2 - dx2 * dy1;
    if (determinant.abs() < 0.00001) {
      throw const FormatException('Degenerate document corners.');
    }
    final g = (dx3 * dy2 - dx2 * dy3) / determinant;
    final h = (dx1 * dy3 - dx3 * dy1) / determinant;
    return [
      p[1].x - p[0].x + g * p[1].x,
      p[3].x - p[0].x + h * p[3].x,
      p[0].x,
      p[1].y - p[0].y + g * p[1].y,
      p[3].y - p[0].y + h * p[3].y,
      p[0].y,
      g,
      h,
    ];
  }

  static int _luma(img.Pixel p) =>
      (0.299 * p.r + 0.587 * p.g + 0.114 * p.b).round().clamp(0, 255);

  static void _enhance(img.Image image, ScanFilter filter) {
    if (filter == ScanFilter.grayscale) {
      img.grayscale(image);
      return;
    }
    // A broad local background estimate removes uneven lighting. Comparing to
    // the local mean preserves text in shadows, unlike a global threshold.
    final background = img.gaussianBlur(
      _limitSize(img.grayscale(img.Image.from(image)), 256),
      radius: 12,
    );
    for (final p in image) {
      final bx = p.x * (background.width - 1) / max(1, image.width - 1);
      final by = p.y * (background.height - 1) / max(1, image.height - 1);
      final white = max(
        32,
        background.getPixelInterpolate(bx, by).r.toDouble(),
      );
      if (filter == ScanFilter.blackAndWhite) {
        final value = _luma(p) < white * 0.88 ? 0 : 255;
        p.setRgb(value, value, value);
      } else {
        int clean(num channel) =>
            (((channel * 255 / white) - 25) * 255 / 230).round().clamp(0, 255);
        p.setRgb(clean(p.r), clean(p.g), clean(p.b));
      }
    }
  }
}
