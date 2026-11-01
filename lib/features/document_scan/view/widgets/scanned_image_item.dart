import 'dart:io';

import 'package:flutter/material.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

import 'package:photo_view/photo_view.dart';

typedef DeleteCallback = void Function();

class ScannedImageItem extends StatefulWidget {
  final File file;
  final DeleteCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback? onRetake;
  final VoidCallback? onMoveEarlier;
  final VoidCallback? onMoveLater;

  final int index;
  final int totalNumberOfFiles;

  const ScannedImageItem({
    super.key,
    required this.file,
    required this.onDelete,
    required this.onEdit,
    this.onRetake,
    this.onMoveEarlier,
    this.onMoveLater,
    required this.index,
    required this.totalNumberOfFiles,
  });

  @override
  State<ScannedImageItem> createState() => _ScannedImageItemState();
}

class _ScannedImageItemState extends State<ScannedImageItem> {
  @override
  Widget build(BuildContext context) {
    return _buildImageItem(context);
  }

  Widget _buildImageItem(BuildContext context) {
    final s = S.of(context)!;
    final scheme = Theme.of(context).colorScheme;
    return Material(
      color: scheme.surfaceContainerLow,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: scheme.outlineVariant),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: [
          Expanded(
            child: Semantics(
              button: true,
              label: s.scannerPageLabel(widget.index + 1),
              hint: s.previewScan,
              child: InkWell(
                onTap: () => _showImage(context),
                child: Padding(
                  padding: const EdgeInsets.all(8),
                  child: Image.file(
                    widget.file,
                    width: double.infinity,
                    height: double.infinity,
                    fit: BoxFit.contain,
                    excludeFromSemantics: true,
                  ),
                ),
              ),
            ),
          ),
          const Divider(height: 1),
          Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Text(
                      '${widget.index + 1} / ${widget.totalNumberOfFiles}',
                    ),
                  ),
                ),
              ),
              IconButton(
                tooltip: s.edit,
                onPressed: widget.onEdit,
                icon: const Icon(Icons.crop_rotate),
              ),
              PopupMenuButton<String>(
                tooltip: s.scannerPageLabel(widget.index + 1),
                icon: const Icon(Icons.more_vert),
                onSelected: (action) {
                  switch (action) {
                    case 'retake':
                      widget.onRetake?.call();
                    case 'earlier':
                      widget.onMoveEarlier?.call();
                    case 'later':
                      widget.onMoveLater?.call();
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => [
                  if (widget.onRetake != null)
                    PopupMenuItem(
                      value: 'retake',
                      child: Text(S.of(context)!.scannerRetakeCaptured),
                    ),
                  PopupMenuItem(
                    value: 'earlier',
                    enabled: widget.onMoveEarlier != null,
                    child: Text(S.of(context)!.scannerMoveEarlier),
                  ),
                  PopupMenuItem(
                    value: 'later',
                    enabled: widget.onMoveLater != null,
                    child: Text(S.of(context)!.scannerMoveLater),
                  ),
                  PopupMenuItem(
                    value: 'delete',
                    child: Text(
                      s.remove,
                      style: TextStyle(color: scheme.error),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  void _showImage(BuildContext context) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => Scaffold(
          appBar: AppBar(
            title: Text(
              "${S.of(context)!.scan} ${widget.index + 1}/${widget.totalNumberOfFiles}",
            ),
            actions: [
              IconButton(
                tooltip: S.of(context)!.edit,
                onPressed: () {
                  Navigator.pop(context);
                  widget.onEdit();
                },
                icon: const Icon(Icons.crop_rotate),
              ),
            ],
          ),
          body: PhotoView(imageProvider: FileImage(widget.file)),
        ),
      ),
    );
  }
}
