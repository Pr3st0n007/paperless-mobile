import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;

/// A4 physical dimensions rather than treating image pixels as PDF points.
Future<Uint8List> assembleScanPdf(List<Uint8List> pages) async {
  if (pages.isEmpty) throw ArgumentError.value(pages, 'pages', 'No scans.');
  final document = pw.Document(
    title: 'Paperless scan',
    creator: 'Paperless Mobile',
  );
  for (final bytes in pages) {
    final image = pw.MemoryImage(bytes);
    final landscape = image.width! > image.height!;
    document.addPage(
      pw.Page(
        pageFormat: landscape ? PdfPageFormat.a4.landscape : PdfPageFormat.a4,
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
  }
  return document.save();
}
