import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';

class CapturedPage {
  final File originalFile;
  final ScanEdit edit;
  final Uint8List preview;

  const CapturedPage(this.originalFile, this.edit, this.preview);

  CapturedPage copyWith({ScanEdit? edit, Uint8List? preview}) =>
      CapturedPage(originalFile, edit ?? this.edit, preview ?? this.preview);
}

/// Pages captured in the current session that have not been handed to the
/// scan repository yet. Originals live in a private temp directory so memory
/// stays flat regardless of page count.
class CaptureDraft extends ChangeNotifier {
  final ScanPageFormat format;
  final bool formatOverride;
  final _pages = <CapturedPage>[];
  Future<Directory>? _directory;

  CaptureDraft({required this.format, this.formatOverride = false});

  List<CapturedPage> get pages => List.unmodifiable(_pages);
  int get length => _pages.length;
  bool get isEmpty => _pages.isEmpty;

  Future<Directory> _dir() => _directory ??= Directory.systemTemp.createTemp(
    'paperless_scan_draft_',
  );

  /// Detects the page boundary on the full-resolution capture, renders a
  /// preview and stores the original. Replaces [replaceIndex] when given.
  Future<CapturedPage> addCapture(Uint8List original, {int? replaceIndex}) async {
    final analysis = await compute(DocumentProcessor.analyze, original);
    final edit = ScanEdit(
      corners: analysis.detectedCorners ?? ScanEdit.fullPage,
      pageFormat: format,
      formatOverride: formatOverride,
    );
    final preview = await compute(
      DocumentProcessor.render,
      ScanRenderRequest(original, edit, preview: true),
    );
    final directory = await _dir();
    final file = File(
      '${directory.path}/page_${DateTime.now().microsecondsSinceEpoch}.jpg',
    );
    await file.writeAsBytes(original, flush: true);
    final page = CapturedPage(file, edit, preview);
    if (replaceIndex != null && replaceIndex >= 0 && replaceIndex < _pages.length) {
      final old = _pages[replaceIndex];
      _pages[replaceIndex] = page;
      notifyListeners();
      await _deleteFile(old.originalFile);
    } else {
      _pages.add(page);
      notifyListeners();
    }
    return page;
  }

  Future<void> applyEdit(int index, ScanEdit edit) async {
    final page = _pages[index];
    final original = await page.originalFile.readAsBytes();
    final preview = await compute(
      DocumentProcessor.render,
      ScanRenderRequest(original, edit, preview: true),
    );
    if (index < _pages.length && identical(_pages[index], page)) {
      _pages[index] = page.copyWith(edit: edit, preview: preview);
      notifyListeners();
    }
  }

  /// Removes a page but keeps its file so the removal can be undone.
  CapturedPage removeAt(int index) {
    final page = _pages.removeAt(index);
    notifyListeners();
    return page;
  }

  void restore(int index, CapturedPage page) {
    _pages.insert(index.clamp(0, _pages.length), page);
    notifyListeners();
  }

  Future<void> discard(CapturedPage page) => _deleteFile(page.originalFile);

  /// Renders every page at full quality and hands it to [save] in order.
  /// Saved pages are removed from the draft so a failure can be retried
  /// without duplicating pages.
  Future<void> commit(
    Future<void> Function(Uint8List original, ScanEditorResult result) save, {
    void Function(int done, int total)? onProgress,
  }) async {
    final total = _pages.length;
    var done = 0;
    while (_pages.isNotEmpty) {
      onProgress?.call(done, total);
      final page = _pages.first;
      final original = await page.originalFile.readAsBytes();
      final rendered = await compute(
        DocumentProcessor.render,
        ScanRenderRequest(original, page.edit),
      );
      await save(original, ScanEditorResult(page.edit, rendered));
      _pages.removeAt(0);
      done++;
      notifyListeners();
    }
    onProgress?.call(done, total);
  }

  Future<void> cleanup() async {
    final pending = _directory;
    _directory = null;
    _pages.clear();
    if (pending == null) return;
    final directory = await pending;
    if (await directory.exists()) await directory.delete(recursive: true);
  }

  static Future<void> _deleteFile(File file) async {
    try {
      await file.delete();
    } on FileSystemException {
      // Already gone.
    }
  }
}
