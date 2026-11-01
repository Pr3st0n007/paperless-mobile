import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';

class ScanEditorResult {
  final ScanEdit edit;
  final Uint8List rendered;

  const ScanEditorResult(this.edit, this.rendered);
}

class ScanEditorPage extends StatefulWidget {
  final Uint8List original;
  final ScanEdit? initialEdit;
  final ScanPageFormat scanFormat;
  final Future<void> Function(ScanEditorResult result)? onSave;

  const ScanEditorPage({
    super.key,
    required this.original,
    this.initialEdit,
    this.scanFormat = ScanPageFormat.auto,
    this.onSave,
  });

  @override
  State<ScanEditorPage> createState() => _ScanEditorPageState();
}

class _ScanEditorPageState extends State<ScanEditorPage> {
  ScanAnalysis? _analysis;
  ScanEdit? _edit;
  ScanEdit? _baseline;
  Uint8List? _preview;
  bool _busy = true;
  bool _cropping = true;
  bool _failed = false;
  int? _draggedCorner;

  bool get _hasChanges {
    final edit = _edit;
    final baseline = _baseline;
    return edit != null &&
        baseline != null &&
        (!listEquals(edit.corners, baseline.corners) ||
            edit.filter != baseline.filter ||
            edit.quarterTurns != baseline.quarterTurns ||
            edit.pageFormat != baseline.pageFormat ||
            edit.formatOverride != baseline.formatOverride);
  }

  Future<void> _confirmLeave() async {
    final s = S.of(context)!;
    final discard = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.discardChanges),
        content: Text(s.discardChangesWarning),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text(s.discard),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, false),
            child: Text(s.save),
          ),
        ],
      ),
    );
    if (!mounted) return;
    if (discard == true) {
      Navigator.pop(context);
    } else if (discard == false) {
      await _render(save: true);
    }
  }

  @override
  void initState() {
    super.initState();
    _analyze();
  }

  Future<void> _analyze() async {
    setState(() {
      _busy = true;
      _failed = false;
    });
    try {
      final analysis = await compute(
        DocumentProcessor.analyze,
        widget.original,
      );
      if (!mounted) return;
      setState(() {
        _analysis = analysis;
        final initial = widget.initialEdit;
        _edit = initial == null
            ? ScanEdit(
                corners: analysis.detectedCorners ?? ScanEdit.fullPage,
                pageFormat: widget.scanFormat,
              )
            : initial.formatOverride
            ? initial
            : initial.copyWith(pageFormat: widget.scanFormat);
        _baseline = _edit;
        _busy = false;
      });
    } catch (error, stackTrace) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _failed = true;
      });
      showGenericError(context, error, stackTrace);
    }
  }

  Future<void> _render({bool save = false}) async {
    setState(() => _busy = true);
    try {
      final bytes = await compute(
        DocumentProcessor.render,
        ScanRenderRequest(widget.original, _edit!, preview: !save),
      );
      if (!mounted) return;
      if (save) {
        final result = ScanEditorResult(_edit!, bytes);
        await widget.onSave?.call(result);
        if (mounted) Navigator.pop(context, result);
      } else {
        setState(() {
          _preview = bytes;
          _cropping = false;
        });
      }
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<ScanPageFormat?> _customPageFormat() async {
    final s = S.of(context)!;
    final current = _edit!.pageFormat;
    final width = TextEditingController(
      text: current.kind == ScanPageFormatKind.custom
          ? current.widthMm.toString()
          : '',
    );
    final height = TextEditingController(
      text: current.kind == ScanPageFormatKind.custom
          ? current.heightMm.toString()
          : '',
    );
    final result = await showDialog<ScanPageFormat>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.scannerFormatCustom),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: width,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: s.scannerCustomWidth),
            ),
            TextField(
              controller: height,
              keyboardType: const TextInputType.numberWithOptions(
                decimal: true,
              ),
              decoration: InputDecoration(labelText: s.scannerCustomHeight),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.cancel),
          ),
          FilledButton(
            onPressed: () {
              final widthMm = double.tryParse(width.text);
              final heightMm = double.tryParse(height.text);
              if (widthMm == null ||
                  heightMm == null ||
                  !widthMm.isFinite ||
                  !heightMm.isFinite ||
                  widthMm <= 0 ||
                  heightMm <= 0) {
                showSnackBar(
                  context,
                  s.scannerInvalidDimensions,
                  type: SnackbarType.error,
                );
                return;
              }
              try {
                Navigator.pop(
                  context,
                  ScanPageFormat.custom(widthMm, heightMm),
                );
              } on ArgumentError {
                showSnackBar(
                  context,
                  s.scannerInvalidDimensions,
                  type: SnackbarType.error,
                );
              }
            },
            child: Text(s.save),
          ),
        ],
      ),
    );
    width.dispose();
    height.dispose();
    return result;
  }

  Future<void> _selectPageFormat(ScanPageFormatKind kind) async {
    final format = switch (kind) {
      ScanPageFormatKind.auto => ScanPageFormat.auto,
      ScanPageFormatKind.a4 => ScanPageFormat.a4,
      ScanPageFormatKind.letter => ScanPageFormat.letter,
      ScanPageFormatKind.custom => await _customPageFormat(),
    };
    if (format == null || !mounted) return;
    setState(
      () => _edit = _edit!.copyWith(pageFormat: format, formatOverride: true),
    );
    if (!_cropping) _render();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    final hint = _cropping
        ? (_analysis?.detectedCorners == null
              ? s.scannerManualCropHint
              : s.scannerCropHint)
        : s.scannerPreviewHint;
    return PopScope(
      canPop: !_busy && !_hasChanges,
      onPopInvokedWithResult: (didPop, _) {
        if (!didPop && !_busy) _confirmLeave();
      },
      child: Scaffold(
        appBar: AppBar(
          title: Text(
            s.scannerEditPage,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          actions: [
            IconButton(
              tooltip: hint,
              onPressed: _busy
                  ? null
                  : () => showDialog<void>(
                      context: context,
                      builder: (context) => AlertDialog(
                        content: Text(hint),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: Text(s.close),
                          ),
                        ],
                      ),
                    ),
              icon: const Icon(Icons.info_outline),
            ),
            Padding(
              padding: const EdgeInsets.only(right: 12),
              child: ConstrainedBox(
                constraints: BoxConstraints(
                  maxWidth: min(180, MediaQuery.sizeOf(context).width * .45),
                ),
                child: FilledButton(
                  onPressed: _busy || _edit == null
                      ? null
                      : () => _render(save: true),
                  child: FittedBox(fit: BoxFit.scaleDown, child: Text(s.save)),
                ),
              ),
            ),
          ],
        ),
        body: _failed
            ? Center(
                child: TextButton(
                  onPressed: _analyze,
                  child: Text(s.scannerRetry),
                ),
              )
            : Stack(
                children: [
                  AbsorbPointer(
                    absorbing: _busy,
                    child: SafeArea(
                      top: false,
                      child: LayoutBuilder(
                        builder: (context, constraints) {
                          final sideBySide =
                              constraints.maxWidth >= 700 &&
                              constraints.maxWidth > constraints.maxHeight;
                          final preview = Expanded(child: _buildPreview());
                          if (_edit == null) return _buildPreview();
                          if (sideBySide) {
                            return Row(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              children: [
                                preview,
                                const VerticalDivider(width: 1),
                                SizedBox(
                                  width: min(400, constraints.maxWidth * .4),
                                  child: _buildControls(),
                                ),
                              ],
                            );
                          }
                          return Column(
                            children: [
                              preview,
                              const Divider(height: 1),
                              ConstrainedBox(
                                constraints: BoxConstraints(
                                  maxHeight: min(
                                    360,
                                    constraints.maxHeight * .45,
                                  ),
                                ),
                                child: _buildControls(),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ),
                  if (_busy)
                    const Positioned.fill(
                      child: ColoredBox(
                        color: Colors.black38,
                        child: Center(child: CircularProgressIndicator()),
                      ),
                    ),
                ],
              ),
      ),
    );
  }

  Widget _buildPreview() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surfaceContainerLowest,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _analysis == null
            ? const SizedBox.expand()
            : _cropping
            ? _buildCrop()
            : InteractiveViewer(
                key: ValueKey(_preview),
                minScale: 1,
                maxScale: 5,
                child: Image.memory(
                  _preview!,
                  width: double.infinity,
                  height: double.infinity,
                  fit: BoxFit.contain,
                  gaplessPlayback: true,
                ),
              ),
      ),
    );
  }

  Widget _buildCrop() {
    final analysis = _analysis!;
    return LayoutBuilder(
      builder: (context, constraints) {
        final size = applyBoxFit(
          BoxFit.contain,
          Size(analysis.width.toDouble(), analysis.height.toDouble()),
          constraints.biggest,
        ).destination;
        return Center(
          child: SizedBox(
            width: size.width,
            height: size.height,
            child: GestureDetector(
              onPanStart: _busy
                  ? null
                  : (details) {
                      final position = details.localPosition;
                      var nearest = 0;
                      var distance = double.infinity;
                      for (var i = 0; i < 4; i++) {
                        final p = _edit!.corners[i];
                        final d =
                            (Offset(p.x * size.width, p.y * size.height) -
                                    position)
                                .distance;
                        if (d < distance) {
                          distance = d;
                          nearest = i;
                        }
                      }
                      _draggedCorner = distance < 64 ? nearest : null;
                    },
              onPanUpdate: _busy
                  ? null
                  : (details) {
                      final index = _draggedCorner;
                      if (index == null) return;
                      final corners = [..._edit!.corners];
                      corners[index] = Point(
                        (details.localPosition.dx / size.width)
                            .clamp(0, 1)
                            .toDouble(),
                        (details.localPosition.dy / size.height)
                            .clamp(0, 1)
                            .toDouble(),
                      );
                      if (ScanEdit.isValidCorners(corners)) {
                        setState(
                          () => _edit = _edit!.copyWith(corners: corners),
                        );
                      }
                    },
              onPanEnd: (_) => _draggedCorner = null,
              child: CustomPaint(
                foregroundPainter: _CropPainter(
                  _edit!.corners,
                  Theme.of(context).colorScheme.primary,
                ),
                child: Image.memory(analysis.preview, fit: BoxFit.fill),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildControls() {
    final s = S.of(context)!;
    return SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          _buildEditActions(),
          const SizedBox(height: 12),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              for (final filter in ScanFilter.values)
                ChoiceChip(
                  materialTapTargetSize: MaterialTapTargetSize.padded,
                  label: Text(switch (filter) {
                    ScanFilter.document => s.scannerDocumentFilter,
                    ScanFilter.color => s.color,
                    ScanFilter.grayscale => s.scannerGrayscale,
                    ScanFilter.blackAndWhite => s.scannerBlackAndWhite,
                  }),
                  selected: _edit!.filter == filter,
                  onSelected: _busy
                      ? null
                      : (_) {
                          setState(() {
                            _edit = _edit!.copyWith(filter: filter);
                          });
                          if (!_cropping) _render();
                        },
                ),
            ],
          ),
          if (defaultTargetPlatform == TargetPlatform.android) ...[
            const SizedBox(height: 16),
            Text(
              s.scannerOutputFormat,
              style: Theme.of(context).textTheme.labelLarge,
            ),
            const SizedBox(height: 8),
            InputDecorator(
              decoration: const InputDecoration(
                contentPadding: EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 4,
                ),
              ),
              child: DropdownButtonHideUnderline(
                child: DropdownButton<ScanPageFormatKind>(
                  isExpanded: true,
                  itemHeight: null,
                  value: _edit!.pageFormat.kind,
                  onChanged: _busy
                      ? null
                      : (kind) {
                          if (kind != null) _selectPageFormat(kind);
                        },
                  items: [
                    DropdownMenuItem(
                      value: ScanPageFormatKind.auto,
                      child: Text(
                        s.scannerFormatAuto,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    DropdownMenuItem(
                      value: ScanPageFormatKind.a4,
                      child: Text(s.scannerFormatA4),
                    ),
                    DropdownMenuItem(
                      value: ScanPageFormatKind.letter,
                      child: Text(s.scannerFormatLetter),
                    ),
                    DropdownMenuItem(
                      value: ScanPageFormatKind.custom,
                      child: Text(
                        s.scannerFormatCustom,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_edit!.formatOverride)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  s.scannerFormatOverride,
                  style: Theme.of(context).textTheme.bodySmall,
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _buildEditActions() {
    final s = S.of(context)!;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SegmentedButton<bool>(
          segments: [
            ButtonSegment(
              value: true,
              icon: const Icon(Icons.crop),
              label: Text(s.scannerCrop),
            ),
            ButtonSegment(
              value: false,
              icon: const Icon(Icons.preview_outlined),
              label: Text(s.previewScan),
            ),
          ],
          selected: {_cropping},
          showSelectedIcon: false,
          onSelectionChanged: _busy
              ? null
              : (selection) {
                  if (selection.single) {
                    setState(() => _cropping = true);
                  } else {
                    _render();
                  }
                },
        ),
        const SizedBox(height: 8),
        Row(
          mainAxisAlignment: MainAxisAlignment.end,
          children: [
            IconButton(
              tooltip: s.scannerRotate,
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _edit = _edit!.copyWith(
                          quarterTurns: (_edit!.quarterTurns + 1) % 4,
                        );
                      });
                      _render();
                    },
              icon: const Icon(Icons.rotate_right),
            ),
            IconButton(
              tooltip: s.reset,
              onPressed: _busy
                  ? null
                  : () {
                      setState(() {
                        _edit = _edit!.copyWith(
                          corners: ScanEdit.fullPage,
                          quarterTurns: 0,
                          filter: ScanFilter.document,
                        );
                        _cropping = true;
                      });
                    },
              icon: const Icon(Icons.restart_alt),
            ),
          ],
        ),
      ],
    );
  }
}

class _CropPainter extends CustomPainter {
  final List<Point<double>> corners;
  final Color color;

  const _CropPainter(this.corners, this.color);

  @override
  void paint(Canvas canvas, Size size) {
    final points = corners
        .map((p) => Offset(p.x * size.width, p.y * size.height))
        .toList();
    final crop = Path()..addPolygon(points, true);
    final shade = Path()
      ..fillType = PathFillType.evenOdd
      ..addRect(Offset.zero & size)
      ..addPath(crop, Offset.zero);
    canvas.drawPath(shade, Paint()..color = Colors.black54);
    canvas.drawPath(
      crop,
      Paint()
        ..color = color
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
    for (final point in points) {
      canvas.drawCircle(point, 11, Paint()..color = color);
      canvas.drawCircle(point, 5, Paint()..color = Colors.white);
    }
  }

  @override
  bool shouldRepaint(_CropPainter oldDelegate) =>
      oldDelegate.corners != corners || oldDelegate.color != color;
}
