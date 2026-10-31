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
  Uint8List? _preview;
  bool _busy = true;
  bool _cropping = true;
  bool _failed = false;
  int? _draggedCorner;

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
      () => _edit = _edit!.copyWith(
        pageFormat: format,
        formatOverride: true,
      ),
    );
    if (!_cropping) _render();
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    return PopScope(
      canPop: !_busy,
      child: Scaffold(
        appBar: AppBar(
          title: Text(s.scannerEditPage),
          actions: [
            TextButton(
              onPressed: _busy || _edit == null
                  ? null
                  : () => _render(save: true),
              child: Text(s.save),
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
                  Column(
                    children: [
                      Padding(
                        padding: const EdgeInsets.all(12),
                        child: Text(
                          _cropping
                              ? (_analysis?.detectedCorners == null
                                    ? s.scannerManualCropHint
                                    : s.scannerCropHint)
                              : s.scannerPreviewHint,
                          textAlign: TextAlign.center,
                        ),
                      ),
                      Expanded(
                        child: Padding(
                          padding: const EdgeInsets.all(24),
                          child: _analysis == null
                              ? const SizedBox.shrink()
                              : _cropping
                              ? _buildCrop()
                              : Image.memory(_preview!, gaplessPlayback: true),
                        ),
                      ),
                      if (_edit != null) _buildControls(),
                    ],
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
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (defaultTargetPlatform == TargetPlatform.android) ...[
              Row(
                children: [
                  Expanded(child: Text(s.scannerOutputFormat)),
                  DropdownButton<ScanPageFormatKind>(
                    value: _edit!.pageFormat.kind,
                    onChanged: _busy
                        ? null
                        : (kind) {
                            if (kind != null) _selectPageFormat(kind);
                          },
                    items: [
                      DropdownMenuItem(
                        value: ScanPageFormatKind.auto,
                        child: Text(s.scannerFormatAuto),
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
                        child: Text(s.scannerFormatCustom),
                      ),
                    ],
                  ),
                ],
              ),
              if (_edit!.formatOverride)
                Align(
                  alignment: Alignment.centerLeft,
                  child: Text(
                    s.scannerFormatOverride,
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
            ],
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  for (final filter in ScanFilter.values)
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      child: ChoiceChip(
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
                    ),
                ],
              ),
            ),
            Wrap(
              alignment: WrapAlignment.center,
              spacing: 8,
              children: [
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          if (_cropping) {
                            _render();
                          } else {
                            setState(() => _cropping = true);
                          }
                        },
                  icon: Icon(_cropping ? Icons.preview : Icons.crop),
                  label: Text(_cropping ? s.previewScan : s.scannerCrop),
                ),
                TextButton.icon(
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
                  label: Text(s.scannerRotate),
                ),
                TextButton.icon(
                  onPressed: _busy
                      ? null
                      : () {
                          setState(() {
                            _edit = ScanEdit(corners: ScanEdit.fullPage);
                            _cropping = true;
                          });
                        },
                  icon: const Icon(Icons.restart_alt),
                  label: Text(s.reset),
                ),
              ],
            ),
          ],
        ),
      ),
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
