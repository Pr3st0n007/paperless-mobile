import 'dart:typed_data';

import 'package:pdf/pdf.dart';
import 'package:pdf/widgets.dart' as pw;
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';

class ScanPdfRequest {
  final List<Uint8List> pages;
  final List<ScanPageFormat> formats;

  const ScanPdfRequest(this.pages, this.formats);
}

Future<Uint8List> assembleScanPdfRequest(ScanPdfRequest request) =>
    assembleScanPdf(request.pages, formats: request.formats);

/// Auto pages use a deterministic 297 mm long side; this does not imply
/// measurement of the photographed document's physical dimensions.
Future<Uint8List> assembleScanPdf(
  List<Uint8List> pages, {
  List<ScanPageFormat>? formats,
}) async {
  if (pages.isEmpty) throw ArgumentError.value(pages, 'pages', 'No scans.');
  if (formats != null && formats.length != pages.length) {
    throw ArgumentError.value(formats, 'formats', 'Must match page count.');
  }
  final document = pw.Document(
    title: 'Paperless scan',
    creator: 'Paperless Mobile',
  );
  for (var index = 0; index < pages.length; index++) {
    final bytes = pages[index];
    final image = pw.MemoryImage(bytes);
    final format = formats == null ? ScanPageFormat.a4 : formats[index];
    final dimensions = format.dimensionsFor(image.width! / image.height!);
    document.addPage(
      pw.Page(
        pageFormat: PdfPageFormat(
          dimensions.$1 * PdfPageFormat.mm,
          dimensions.$2 * PdfPageFormat.mm,
        ),
        margin: pw.EdgeInsets.zero,
        build: (_) => pw.Center(child: pw.Image(image, fit: pw.BoxFit.contain)),
      ),
    );
  }
  return document.save();
}
