import 'dart:math';
import 'dart:typed_data';

import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';

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
      final horizontal =
          hull[0].distanceTo(hull[1]) + hull[2].distanceTo(hull[3]);
      final vertical =
          hull[1].distanceTo(hull[2]) + hull[3].distanceTo(hull[0]);
      final ratio = min(horizontal, vertical) / max(horizontal, vertical);
      if (ratio < 0.4) continue;
      final score = area * (1 - (ratio - 1 / sqrt2).abs());
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
    final landscape = width > height;
    final maxLongSide = request.preview ? 1200 : 3508;
    // Keep source detail without upscaling; cap at approximately A4 / 300 dpi.
    final availableLongSide = min(
      landscape ? width : width * sqrt2,
      landscape ? height * sqrt2 : height,
    );
    final longSide = min(maxLongSide, availableLongSide).floor().clamp(2, 3508);
    final shortSide = max(2, (longSide / sqrt2).floor());
    var result = img.Image(
      width: landscape ? longSide : shortSide,
      height: landscape ? shortSide : longSide,
    );
    final transform = _homography(points);
    for (var y = 0; y < result.height; y++) {
      final v = y / (result.height - 1);
      for (var x = 0; x < result.width; x++) {
        final u = x / (result.width - 1);
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
