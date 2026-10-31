import 'dart:math';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_preview_transform.dart';

img.Image documentFixture({
  int width = 400,
  int height = 500,
  List<Point<double>>? corners,
  bool texturedBackground = false,
}) {
  final quad =
      corners ??
      [
        const Point(60.0, 40.0),
        const Point(330.0, 65.0),
        const Point(350.0, 450.0),
        const Point(40.0, 430.0),
      ];
  final image = img.Image(width: width, height: height);
  for (final p in image) {
    final inside = List.generate(4, (i) {
      final a = quad[i];
      final b = quad[(i + 1) % 4];
      return (b.x - a.x) * (p.y - a.y) - (b.y - a.y) * (p.x - a.x) >= 0;
    }).every((value) => value);
    final value = inside
        ? 240
        : texturedBackground
        ? 20 + ((p.x * 17 + p.y * 13) % 70)
        : 45;
    p.setRgb(value, value, value);
    if (inside && p.x > 90 && p.x < 290 && p.y > 100 && p.y < 380) {
      if (p.y % 30 < 3) p.setRgb(25, 25, 25);
    }
  }
  return image;
}

void main() {
  group('White A4 detection', () {
    test('finds a skewed page with text to within 2% of its corners', () {
      final corners = DocumentProcessor.detectCorners(documentFixture())!;
      final expected = [
        const Point(60 / 399, 40 / 499),
        const Point(330 / 399, 65 / 499),
        const Point(350 / 399, 450 / 499),
        const Point(40 / 399, 430 / 499),
      ];
      for (var i = 0; i < 4; i++) {
        expect(corners[i].distanceTo(expected[i]), lessThan(.02));
      }
    });

    test('detects a landscape page', () {
      final corners = DocumentProcessor.detectCorners(
        documentFixture(
          width: 500,
          height: 400,
          corners: const [
            Point(40.0, 50.0),
            Point(450.0, 40.0),
            Point(430.0, 350.0),
            Point(60.0, 330.0),
          ],
        ),
      );
      expect(corners, isNotNull);
      expect(ScanEdit.isValidCorners(corners!), isTrue);
    });

    test('detects a narrow receipt without standard-page ratio bias', () {
      final corners = DocumentProcessor.detectCorners(
        documentFixture(
          corners: const [
            Point(170.0, 20.0),
            Point(230.0, 25.0),
            Point(225.0, 475.0),
            Point(175.0, 470.0),
          ],
        ),
      );
      expect(corners, isNotNull);
      expect(ScanEdit.isValidCorners(corners!), isTrue);
      final width = corners[0].distanceTo(corners[1]);
      final height = corners[1].distanceTo(corners[2]);
      expect(width / height, lessThan(.2));
    });

    test('finds a page against a varying grayscale background', () {
      final corners = DocumentProcessor.detectCorners(
        documentFixture(texturedBackground: true),
      );
      expect(corners, isNotNull);
      expect(ScanEdit.isValidCorners(corners!), isTrue);
    });

    test('uniform light or dark backgrounds require manual cropping', () {
      for (final value in [20, 240]) {
        final image = img.Image(width: 200, height: 300);
        img.fill(image, color: img.ColorRgb8(value, value, value));
        expect(DocumentProcessor.detectCorners(image), isNull);
      }
    });

    test('small bright specks do not count as a document', () {
      final image = img.Image(width: 200, height: 300);
      img.fill(image, color: img.ColorRgb8(30, 30, 30));
      img.fillRect(
        image,
        x1: 80,
        y1: 120,
        x2: 100,
        y2: 150,
        color: img.ColorRgb8(255, 255, 255),
      );
      expect(DocumentProcessor.detectCorners(image), isNull);
    });
  });

  group('Crop geometry', () {
    test('rejects crossed, concave, tiny and out-of-bounds corners', () {
      for (final corners in [
        [
          ScanEdit.fullPage[0],
          ScanEdit.fullPage[2],
          ScanEdit.fullPage[1],
          ScanEdit.fullPage[3],
        ],
        const [
          Point(0.0, 0.0),
          Point(1.0, 0.0),
          Point(.1, .1),
          Point(0.0, 1.0),
        ],
        const [
          Point(0.0, 0.0),
          Point(.01, 0.0),
          Point(.01, .01),
          Point(0.0, .01),
        ],
        const [
          Point(-.1, 0.0),
          Point(1.0, 0.0),
          Point(1.0, 1.0),
          Point(0.0, 1.0),
        ],
      ]) {
        expect(() => ScanEdit(corners: corners), throwsArgumentError);
      }
    });

    test('recipes round trip and cannot be mutated', () {
      final edit = ScanEdit(
        corners: ScanEdit.fullPage,
        filter: ScanFilter.grayscale,
        quarterTurns: 3,
      );
      final restored = ScanEdit.fromJson(edit.toJson());
      expect(restored.corners, edit.corners);
      expect(restored.filter, edit.filter);
      expect(restored.quarterTurns, 3);
      expect(() => restored.corners.clear(), throwsUnsupportedError);
    });
  });

  group('Processing', () {
    test(
      'large captures are capped at A4 / 300 dpi and previews at 1200 px',
      () {
        final source = img.Image(width: 2600, height: 3700);
        img.fill(source, color: img.ColorRgb8(240, 240, 240));
        final bytes = Uint8List.fromList(img.encodeJpg(source));
        final edit = ScanEdit(
          corners: ScanEdit.fullPage,
          filter: ScanFilter.color,
          pageFormat: ScanPageFormat.a4,
        );
        final result = img.decodeJpg(
          DocumentProcessor.render(ScanRenderRequest(bytes, edit)),
        )!;
        expect(result.height, 3508);
        expect(result.width, 2480);
        final preview = img.decodeJpg(
          DocumentProcessor.render(
            ScanRenderRequest(bytes, edit, preview: true),
          ),
        )!;
        expect(preview.height, lessThanOrEqualTo(1200));
        expect(preview.height, greaterThan(1100));
        expect(preview.width / preview.height, closeTo(1 / sqrt2, .002));
      },
    );

    test('small inputs are not raster-upscaled to fill A4', () {
      final bytes = Uint8List.fromList(
        img.encodeJpg(img.Image(width: 200, height: 282)),
      );
      final result = img.decodeJpg(
        DocumentProcessor.render(
          ScanRenderRequest(
            bytes,
            ScanEdit(corners: ScanEdit.fullPage, filter: ScanFilter.color),
          ),
        ),
      )!;
      expect(result.width, lessThanOrEqualTo(200));
      expect(result.height, lessThanOrEqualTo(282));
    });

    test('rejects undecodable images rather than saving a blank scan', () {
      expect(
        () => DocumentProcessor.analyze(Uint8List.fromList([1, 2, 3])),
        throwsFormatException,
      );
    });

    test('EXIF orientation is applied before detection and rendering', () {
      final source = img.Image(width: 100, height: 200);
      img.fill(source, color: img.ColorRgb8(255, 255, 255));
      source.exif.imageIfd.orientation = 6;
      final bytes = Uint8List.fromList(img.encodeJpg(source));
      final analysis = DocumentProcessor.analyze(bytes);
      expect(analysis.width, 200);
      expect(analysis.height, 100);
      final result = img.decodeJpg(
        DocumentProcessor.render(
          ScanRenderRequest(
            bytes,
            ScanEdit(corners: ScanEdit.fullPage, filter: ScanFilter.color),
          ),
        ),
      )!;
      expect(result.width, greaterThan(result.height));
    });

    test('perspective crop excludes the desk and produces an A4 image', () {
      final bytes = Uint8List.fromList(img.encodePng(documentFixture()));
      final analysis = DocumentProcessor.analyze(bytes);
      final rendered = img.decodeJpg(
        DocumentProcessor.render(
          ScanRenderRequest(
            bytes,
            ScanEdit(
              corners: analysis.detectedCorners!,
              filter: ScanFilter.color,
              pageFormat: ScanPageFormat.a4,
            ),
          ),
        ),
      )!;
      expect(rendered.height / rendered.width, closeTo(sqrt2, .01));
      expect(rendered.getPixel(10, 10).r, greaterThan(210));
      expect(
        rendered.getPixel(rendered.width - 11, rendered.height - 11).r,
        greaterThan(210),
      );
    });

    test(
      'all filters render and 90-degree rotation swaps output dimensions',
      () {
        final source = documentFixture();
        final bytes = Uint8List.fromList(img.encodePng(source));
        final corners = DocumentProcessor.detectCorners(source)!;
        for (final filter in ScanFilter.values) {
          final result = img.decodeJpg(
            DocumentProcessor.render(
              ScanRenderRequest(
                bytes,
                ScanEdit(
                  corners: corners,
                  filter: filter,
                  quarterTurns: 1,
                  pageFormat: ScanPageFormat.a4,
                ),
              ),
            ),
          )!;
          expect(result.width / result.height, closeTo(sqrt2, .01));
          if (filter == ScanFilter.grayscale ||
              filter == ScanFilter.blackAndWhite) {
            final p = result.getPixel(50, 50);
            expect((p.r - p.g).abs(), lessThanOrEqualTo(2));
            expect((p.g - p.b).abs(), lessThanOrEqualTo(2));
          }
        }
      },
    );

    test('Auto output preserves source proportions without added margins', () {
      final source = img.Image(width: 240, height: 600);
      img.fill(source, color: img.ColorRgb8(230, 230, 230));
      final bytes = Uint8List.fromList(img.encodePng(source));
      final rendered = img.decodeJpg(
        DocumentProcessor.render(
          ScanRenderRequest(
            bytes,
            ScanEdit(corners: ScanEdit.fullPage, filter: ScanFilter.color),
          ),
        ),
      )!;
      expect(rendered.width / rendered.height, closeTo(.4, .005));
      expect(rendered.getPixel(1, 200).r, greaterThan(210));
    });

    test('quality thresholds reject blur and severe exposure', () {
      final blank = img.Image(width: 120, height: 160);
      img.fill(blank, color: img.ColorRgb8(220, 220, 220));
      final blurred = DocumentProcessor.assessQuality(
        Uint8List.fromList(img.encodePng(blank)),
      );
      expect(blurred.edgeSharpness, lessThan(5));
      expect(blurred.isAcceptable, isFalse);

      final dark = img.Image(width: 120, height: 160);
      img.fill(dark, color: img.ColorRgb8(20, 20, 20));
      final underexposed = DocumentProcessor.assessQuality(
        Uint8List.fromList(img.encodePng(dark)),
      );
      expect(underexposed.underexposedFraction, greaterThan(.55));
      expect(underexposed.isAcceptable, isFalse);
    });

    test(
      'document and binary filters whiten shadows while preserving text',
      () {
        final image = img.Image(width: 250, height: 354);
        for (final p in image) {
          final background = 110 + (120 * p.x / image.width).round();
          final text = p.y > 50 && p.y < 300 && p.y % 30 < 3;
          p.setRgb(
            text ? 20 : background,
            text ? 20 : background,
            text ? 20 : background,
          );
        }
        final bytes = Uint8List.fromList(img.encodePng(image));
        for (final filter in [ScanFilter.document, ScanFilter.blackAndWhite]) {
          final result = img.decodeJpg(
            DocumentProcessor.render(
              ScanRenderRequest(
                bytes,
                ScanEdit(corners: ScanEdit.fullPage, filter: filter),
              ),
            ),
          )!;
          expect(result.getPixel(30, 75).r, greaterThan(230));
          expect(result.getPixel(30, 121).r, lessThan(70));
        }
      },
    );

    test('preview work is bounded and source bytes remain untouched', () {
      final bytes = Uint8List.fromList(img.encodePng(documentFixture()));
      final copy = Uint8List.fromList(bytes);
      final analysis = DocumentProcessor.analyze(bytes);
      final result = img.decodeJpg(
        DocumentProcessor.render(
          ScanRenderRequest(
            bytes,
            ScanEdit(corners: analysis.detectedCorners!),
            preview: true,
          ),
        ),
      )!;
      expect(max(result.width, result.height), lessThanOrEqualTo(1200));
      expect(bytes, copy);
    });
  });

  group('Live stability', () {
    final corners = ScanEdit.fullPage;

    test('requires four steady frames and loses stable state immediately', () {
      final tracker = ScanBoundaryStability();
      for (var i = 0; i < 3; i++) {
        expect(
          tracker.update(corners).status,
          ScanBoundaryStatus.uncertain,
        );
      }
      final stable = tracker.update(corners);
      expect(stable.status, ScanBoundaryStatus.stable);
      expect(stable.transitionedToStable, isTrue);

      final lost = tracker.update(null);
      expect(lost.status, ScanBoundaryStatus.uncertain);
      expect(lost.corners, isNull);
      expect(lost.transitionedToUnstable, isTrue);
    });

    test('corner jitter resets stability and page change uses Hamming threshold', () {
      final tracker = ScanBoundaryStability();
      for (var i = 0; i < 4; i++) {
        tracker.update(corners);
      }
      final moved = [
        const Point(.1, .1),
        const Point(.9, .1),
        const Point(.9, .9),
        const Point(.1, .9),
      ];
      expect(tracker.update(moved).status, ScanBoundaryStatus.uncertain);
      expect(
        hasClearPageChange(
          Uint8List(100),
          Uint8List.fromList(List.filled(100, 1)),
        ),
        isTrue,
      );
      expect(
        hasClearPageChange(Uint8List(100), Uint8List(10)),
        isFalse,
      );
    });

    test('auto gate requires quality, suppresses repeats and rearms on page change', () {
      final gate = ScanAutoCaptureGate()..setEnabled(true);
      expect(
        gate.shouldCapture(
          stable: false,
          qualityAcceptable: true,
          retaking: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: false,
          retaking: false,
        ),
        isFalse,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: true,
        ),
        isFalse,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: false,
        ),
        isTrue,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: false,
        ),
        isFalse,
      );
      final original = Uint8List(256);
      gate.pageCaptured(corners: corners, fingerprint: original);
      expect(
        gate.observe(corners: corners, fingerprint: original),
        isFalse,
      );
      expect(
        gate.observe(
          corners: corners,
          fingerprint: Uint8List.fromList(List.filled(256, 1)),
        ),
        isTrue,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: false,
        ),
        isTrue,
      );
    });

    test('auto gate rearms only after five missing frames', () {
      final gate = ScanAutoCaptureGate()..setEnabled(true);
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: false,
        ),
        isTrue,
      );
      gate.pageCaptured(corners: corners, fingerprint: Uint8List(256));
      for (var i = 0; i < 4; i++) {
        expect(
          gate.observe(corners: null, fingerprint: Uint8List(0)),
          isFalse,
        );
      }
      expect(
        gate.observe(corners: null, fingerprint: Uint8List(0)),
        isTrue,
      );
      expect(
        gate.shouldCapture(
          stable: true,
          qualityAcceptable: true,
          retaking: false,
        ),
        isTrue,
      );
    });
  });

  test('camera corners rotate and map through preview cover cropping', () {
    final rotated = ScanPreviewTransform.rotateCorners(
      const [
        Point(0.0, 0.0),
        Point(1.0, 0.0),
        Point(1.0, 1.0),
        Point(0.0, 1.0),
      ],
      90,
    );
    expect(rotated, const [
      Point(1.0, 0.0),
      Point(1.0, 1.0),
      Point(0.0, 1.0),
      Point(0.0, 0.0),
    ]);
    final mapped = ScanPreviewTransform.mapToViewport(
      corners: const [Point(0.0, 0.0), Point(1.0, 1.0)],
      sourceWidth: 480,
      sourceHeight: 640,
      viewportWidth: 400,
      viewportHeight: 800,
    );
    expect(mapped[0], const Point(-100.0, 0.0));
    expect(mapped[1], const Point(500.0, 800.0));
  });
}
