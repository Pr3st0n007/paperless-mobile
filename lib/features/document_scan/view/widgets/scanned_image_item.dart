import 'dart:io';

import 'package:flutter/material.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

import 'package:photo_view/photo_view.dart';

typedef DeleteCallback = void Function();

class ScannedImageItem extends StatefulWidget {
  final File file;
  final DeleteCallback onDelete;
  final VoidCallback onEdit;
  final VoidCallback? onMoveEarlier;
  final VoidCallback? onMoveLater;

  final int index;
  final int totalNumberOfFiles;

  const ScannedImageItem({
    super.key,
    required this.file,
    required this.onDelete,
    required this.onEdit,
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
    final borderRadius = BorderRadius.circular(12);
    return ClipRRect(
      child: Card(
        shape: RoundedRectangleBorder(borderRadius: borderRadius),
        clipBehavior: Clip.antiAliasWithSaveLayer,
        child: Stack(
          clipBehavior: Clip.antiAliasWithSaveLayer,
          children: [
            Align(
              alignment: Alignment.topCenter,
              child: ClipRRect(
                borderRadius: borderRadius,
                child: SizedBox(
                  height: 100,
                  child: Stack(
                    children: [
                      GestureDetector(
                        onTap: () => _showImage(context),
                        child: SizedBox(
                          width: double.infinity,
                          height: 100,
                          child: Image.file(widget.file, fit: BoxFit.cover),
                        ),
                      ),
                      Positioned(
                        top: 0,
                        right: 0,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8.0,
                            vertical: 4.0,
                          ),
                          decoration: BoxDecoration(
                            color: Theme.of(context).colorScheme.surface,
                            borderRadius: const BorderRadius.only(
                              bottomLeft: Radius.circular(12),
                            ),
                          ),
                          child: Text(
                            "${widget.index + 1}/${widget.totalNumberOfFiles}",
                            style: Theme.of(context).textTheme.bodySmall,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Align(
              alignment: Alignment.bottomCenter,
              child: PopupMenuButton<String>(
                tooltip: S.of(context)!.edit,
                icon: const Icon(Icons.more_horiz),
                onSelected: (action) {
                  switch (action) {
                    case 'edit':
                      widget.onEdit();
                    case 'earlier':
                      widget.onMoveEarlier?.call();
                    case 'later':
                      widget.onMoveLater?.call();
                    case 'delete':
                      widget.onDelete();
                  }
                },
                itemBuilder: (context) => [
                  PopupMenuItem(
                    value: 'edit',
                    child: Text(S.of(context)!.edit),
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
                    child: Text(S.of(context)!.remove),
                  ),
                ],
              ),
            ),
          ],
        ),
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
          ),
          body: PhotoView(imageProvider: FileImage(widget.file)),
        ),
      ),
    );
  }
}
