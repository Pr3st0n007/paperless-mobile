import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_animate/flutter_animate.dart';
import 'package:paperless_mobile/core/extensions/flutter_extensions.dart';
import 'package:pdfx/pdfx.dart';

/// A viewer for PDF documents.
///
/// Displays PDF pages with navigation controls (previous/next page)
/// and a page number indicator.
class PdfDocumentViewer extends StatefulWidget {
  final Uint8List bytes;
  final String? title;
  final bool showAppBar;
  final bool showControls;

  const PdfDocumentViewer({
    super.key,
    required this.bytes,
    this.title,
    this.showAppBar = true,
    this.showControls = true,
  });

  @override
  State<PdfDocumentViewer> createState() => _PdfDocumentViewerState();
}

class _PdfDocumentViewerState extends State<PdfDocumentViewer> {
  late final PdfController _controller;
  int _currentPage = 1;
  int? _totalPages;

  @override
  void initState() {
    super.initState();
    _controller = PdfController(document: PdfDocument.openData(widget.bytes));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final pageTransitionDuration = MediaQuery.disableAnimationsOf(context)
        ? Duration.zero
        : 100.milliseconds;
    // _totalPages is only set once the PdfView using _controller has loaded the document.
    final isReady = _totalPages != null;
    final canGoToNextPage = isReady && _currentPage < _totalPages!;
    final canGoToPreviousPage = isReady && _currentPage > 1;

    return Scaffold(
      appBar: widget.showAppBar
          ? AppBar(title: widget.title != null ? Text(widget.title!) : null)
          : null,
      bottomNavigationBar: _buildControls(
        canGoToPreviousPage,
        pageTransitionDuration,
        canGoToNextPage,
      ),
      body: PdfDocumentPageView(
        bytes: widget.bytes,
        controller: _controller,
        onInitialized: (pagesCount) {
          setState(() {
            _totalPages = pagesCount;
            _currentPage = _controller.page;
          });
        },
        onPageChanged: (page) {
          setState(() {
            _currentPage = page;
          });
        },
      ),
    );
  }

  Future<void> _goToPage(int page, Duration duration) async {
    final total = _totalPages;
    if (!mounted || total == null || page < 1 || page > total) return;
    if (duration == Duration.zero) {
      _controller.jumpToPage(page);
    } else {
      await _controller.animateToPage(
        page,
        duration: duration,
        curve: Curves.easeOut,
      );
    }
  }

  Widget? _buildControls(
    bool canGoToPreviousPage,
    Duration pageTransitionDuration,
    bool canGoToNextPage,
  ) {
    if (!widget.showControls) {
      return null;
    }
    return BottomAppBar(
      child: Row(
        children: [
          Flexible(
            child: Row(
              children: [
                IconButton.filled(
                  onPressed: canGoToPreviousPage
                      ? () =>
                            _goToPage(_currentPage - 1, pageTransitionDuration)
                      : null,
                  icon: const Icon(Icons.arrow_left),
                ),
                const SizedBox(width: 16),
                IconButton.filled(
                  onPressed: canGoToNextPage
                      ? () =>
                            _goToPage(_currentPage + 1, pageTransitionDuration)
                      : null,
                  icon: const Icon(Icons.arrow_right),
                ),
              ],
            ),
          ),
          PdfPageNumber(
            controller: _controller,
            builder: (context, loadingState, page, pagesCount) {
              return Text(
                pagesCount == null ? "-/-" : "$page/$pagesCount",
                style: Theme.of(context).textTheme.titleMedium,
              ).padded();
            },
          ),
        ],
      ),
    );
  }
}

/// A standalone PDF page view widget that renders PDF pages and reports
/// page changes and initialization events.
class PdfDocumentPageView extends StatefulWidget {
  final Uint8List bytes;
  final ValueChanged<int> onPageChanged;
  final ValueChanged<int> onInitialized;

  /// Controller to attach to the rendered [PdfView]. If omitted, an internal
  /// one is created and disposed with this widget.
  final PdfController? controller;

  const PdfDocumentPageView({
    super.key,
    required this.bytes,
    required this.onPageChanged,
    required this.onInitialized,
    this.controller,
  });

  @override
  State<PdfDocumentPageView> createState() => _PdfDocumentPageViewState();
}

class _PdfDocumentPageViewState extends State<PdfDocumentPageView> {
  PdfController? _ownedController;

  PdfController get _controller => widget.controller ?? _ownedController!;

  @override
  void initState() {
    super.initState();
    if (widget.controller == null) {
      _ownedController = PdfController(
        document: PdfDocument.openData(widget.bytes),
      );
    }
  }

  @override
  void dispose() {
    _ownedController?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return PdfView(
      controller: _controller,
      onDocumentLoaded: (document) {
        if (mounted) {
          widget.onInitialized(document.pagesCount);
        }
      },
      onPageChanged: (page) {
        if (mounted) {
          widget.onPageChanged(page);
        }
      },
    );
  }
}
