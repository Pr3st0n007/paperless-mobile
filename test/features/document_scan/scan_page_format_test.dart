import 'package:flutter_test/flutter_test.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';

void main() {
  test('Auto uses a 297 mm long-side convention and preserves ratio', () {
    expect(ScanPageFormat.auto.dimensionsFor(0.25), (74.25, 297.0));
    expect(ScanPageFormat.auto.dimensionsFor(4), (297.0, 74.25));
  });

  test('standard formats orient to content and custom dimensions round trip', () {
    expect(ScanPageFormat.a4.dimensionsFor(.5), (210.0, 297.0));
    expect(ScanPageFormat.a4.dimensionsFor(2), (297.0, 210.0));
    expect(ScanPageFormat.letter.dimensionsFor(.5), (215.9, 279.4));
    expect(ScanPageFormat.letter.dimensionsFor(2), (279.4, 215.9));

    final custom = ScanPageFormat.custom(100, 250);
    expect(custom.dimensionsFor(.5), (100.0, 250.0));
    expect(custom.dimensionsFor(2), (250.0, 100.0));
    expect(ScanPageFormat.fromJson(custom.toJson()), custom);
  });

  test('custom dimensions reject nonpositive and nonfinite values', () {
    for (final (width, height) in [
      (0.0, 100.0),
      (100.0, -1.0),
      (double.infinity, 200.0),
      (100.0, double.nan),
    ]) {
      expect(
        () => ScanPageFormat.custom(width, height),
        throwsArgumentError,
      );
    }
    expect(
      ScanPageFormat.custom(1, 10000000).dimensionsFor(.5),
      (1.0, 10000000.0),
    );
  });

  test('legacy edit recipes default to Auto and explicit overrides round trip', () {
    final legacy = ScanEdit(
      corners: ScanEdit.fullPage,
    ).toJson()..remove('pageFormat');
    final restored = ScanEdit.fromJson(legacy);
    expect(restored.pageFormat, ScanPageFormat.auto);
    expect(restored.formatOverride, isFalse);

    final overridden = restored.copyWith(
      pageFormat: ScanPageFormat.letter,
      formatOverride: true,
    );
    expect(
      ScanEdit.fromJson(overridden.toJson()).formatOverride,
      isTrue,
    );
    expect(
      ScanEdit.fromJson(overridden.toJson()).pageFormat,
      ScanPageFormat.letter,
    );
  });
}
