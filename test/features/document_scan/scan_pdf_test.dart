import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/services/scan_pdf.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';

void main() {
  test('PDF has one correctly oriented A4 media box per page', () async {
    final portrait = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 100, height: 141)),
    );
    final landscape = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 141, height: 100)),
    );
    final bytes = await assembleScanPdf([portrait, landscape]);
    final pdf = latin1.decode(bytes);
    expect(pdf.startsWith('%PDF'), isTrue);
    final boxes = RegExp(
      r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
    ).allMatches(pdf).toList();
    expect(boxes, hasLength(2));
    expect(double.parse(boxes[0].group(1)!), closeTo(595.28, .01));
    expect(double.parse(boxes[0].group(2)!), closeTo(841.89, .01));
    expect(double.parse(boxes[1].group(1)!), closeTo(841.89, .01));
    expect(double.parse(boxes[1].group(2)!), closeTo(595.28, .01));
    expect(RegExp(r'/Type\s*/Page\b').allMatches(pdf).length, 2);
  });

  test('empty batches are rejected', () async {
    await expectLater(assembleScanPdf([]), throwsArgumentError);
  });

  test('A4, Letter, custom and Auto PDF pages have requested dimensions', () async {
    final page = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 100, height: 200)),
    );
    final formats = [
      ScanPageFormat.a4,
      ScanPageFormat.letter,
      ScanPageFormat.custom(100, 200),
      ScanPageFormat.auto,
    ];
    final bytes = await assembleScanPdf(
      List.filled(formats.length, page),
      formats: formats,
    );
    final pdf = latin1.decode(bytes);
    final boxes = RegExp(
      r'/MediaBox\s*\[\s*0\s+0\s+([\d.]+)\s+([\d.]+)\s*\]',
    ).allMatches(pdf).toList();
    expect(boxes, hasLength(4));
    expect(double.parse(boxes[0].group(1)!), closeTo(595.28, .02));
    expect(double.parse(boxes[0].group(2)!), closeTo(841.89, .02));
    expect(double.parse(boxes[1].group(1)!), closeTo(612.0, .02));
    expect(double.parse(boxes[1].group(2)!), closeTo(792.0, .02));
    expect(double.parse(boxes[2].group(1)!), closeTo(283.46, .02));
    expect(double.parse(boxes[2].group(2)!), closeTo(566.93, .02));
    expect(double.parse(boxes[3].group(1)!), closeTo(420.94, .02));
    expect(double.parse(boxes[3].group(2)!), closeTo(841.89, .02));
  });

  test('format count must match page count', () async {
    final page = Uint8List.fromList(
      img.encodeJpg(img.Image(width: 10, height: 10)),
    );
    await expectLater(
      assembleScanPdf([page], formats: [ScanPageFormat.a4, ScanPageFormat.letter]),
      throwsArgumentError,
    );
  });
}
