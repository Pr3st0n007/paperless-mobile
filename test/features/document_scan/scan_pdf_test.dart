import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:image/image.dart' as img;
import 'package:paperless_mobile/features/document_scan/services/scan_pdf.dart';

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
}
