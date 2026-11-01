import 'package:flutter/material.dart';
import 'package:paperless_mobile/features/document_scan/capture/capture_draft.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';

enum CapturedPageAction { edit, retake, delete }

/// Review sheet for a captured page: large preview plus large-target actions
/// (replaces the former 18 px overflow menu on the thumbnail).
Future<CapturedPageAction?> showCapturedPageSheet(
  BuildContext context, {
  required CapturedPage page,
  required int index,
  required bool canRetake,
}) {
  final s = S.of(context)!;
  return showModalBottomSheet<CapturedPageAction>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            s.scannerPageLabel(index + 1),
            style: Theme.of(context).textTheme.titleMedium,
          ),
          const SizedBox(height: 12),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.45,
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 24),
              child: Image.memory(
                page.preview,
                fit: BoxFit.contain,
                semanticLabel: s.scannerPageLabel(index + 1),
              ),
            ),
          ),
          const SizedBox(height: 8),
          ListTile(
            leading: const Icon(Icons.crop_rotate),
            title: Text(s.scannerEditCaptured),
            onTap: () => Navigator.pop(context, CapturedPageAction.edit),
          ),
          if (canRetake)
            ListTile(
              leading: const Icon(Icons.refresh),
              title: Text(s.scannerRetakeCaptured),
              onTap: () => Navigator.pop(context, CapturedPageAction.retake),
            ),
          ListTile(
            leading: Icon(
              Icons.delete_outline,
              color: Theme.of(context).colorScheme.error,
            ),
            title: Text(
              s.scannerDeleteCaptured,
              style: TextStyle(color: Theme.of(context).colorScheme.error),
            ),
            onTap: () => Navigator.pop(context, CapturedPageAction.delete),
          ),
        ],
      ),
    ),
  );
}
