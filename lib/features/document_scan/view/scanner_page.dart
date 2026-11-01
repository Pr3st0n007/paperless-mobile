import 'dart:io';
import 'dart:math';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:paperless_mobile/api/paperless_api.dart';
import 'package:paperless_mobile/constants.dart';
import 'package:paperless_mobile/core/bloc/loading_status.dart';
import 'package:paperless_mobile/core/extensions/context_extensions.dart';
import 'package:paperless_mobile/core/global/constants.dart';
import 'package:paperless_mobile/features/app_drawer/view/app_drawer.dart';
import 'package:paperless_mobile/features/document_scan/cubit/document_scanner_cubit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_pdf.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_capture_page.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/features/document_scan/view/widgets/export_scans_dialog.dart';
import 'package:paperless_mobile/features/document_scan/view/widgets/scanned_image_item.dart';
import 'package:paperless_mobile/features/document_upload/view/document_upload_preparation_page.dart';
import 'package:paperless_mobile/features/documents/view/pages/document_view.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/connectivity_aware_action_wrapper.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';
import 'package:paperless_mobile/helpers/permission_helpers.dart';
import 'package:paperless_mobile/routing/routes/scanner_route.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage> {
  bool _working = false;

  Future<void> _runOperation(Future<void> Function() operation) async {
    if (_working) return;
    setState(() => _working = true);
    try {
      await operation();
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final s = S.of(context)!;
    return AbsorbPointer(
      absorbing: _working,
      child: Scaffold(
        drawer: const AppDrawer(),
        appBar: AppBar(
          title: Text(s.scanner),
          actions: [
            IconButton(
              tooltip: s.uploadADocumentFromThisDevice,
              onPressed: () => _runOperation(_onUploadFromFilesystem),
              icon: const Icon(Icons.file_upload_outlined),
            ),
          ],
        ),
        floatingActionButton:
            BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
              builder: (context, state) => state.scans.isEmpty
                  ? const SizedBox.shrink()
                  : FloatingActionButton.extended(
                      heroTag: 'fab_document_edit',
                      onPressed: () =>
                          _runOperation(() => _openDocumentScanner(context)),
                      icon: const Icon(Icons.add_a_photo_outlined),
                      label: Text(s.scan),
                    ),
            ),
        bottomNavigationBar: _buildActions(),
        body: Stack(
          children: [
            BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
              builder: (context, state) {
                return switch (state.status) {
                  LoadingStatus.initial => _buildEmptyState(),
                  LoadingStatus.loading => const Center(
                    child: CircularProgressIndicator(),
                  ),
                  LoadingStatus.loaded => _buildImageGrid(
                    state.scans,
                    state.revision,
                  ),
                  LoadingStatus.error => Center(
                    child: TextButton(
                      onPressed: context
                          .read<DocumentScannerCubit>()
                          .initialize,
                      child: Text(S.of(context)!.scannerRestoreFailed),
                    ),
                  ),
                };
              },
            ),
            if (_working)
              const Positioned(
                top: 0,
                left: 0,
                right: 0,
                child: LinearProgressIndicator(),
              ),
          ],
        ),
      ),
    );
  }

  Widget _buildActions() {
    return BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
      builder: (context, state) {
        if (state.scans.isEmpty || state.status != LoadingStatus.loaded) {
          return const SizedBox.shrink();
        }
        final s = S.of(context)!;
        final format = context.read<DocumentScannerCubit>().scanFormat;
        return Material(
          color: Theme.of(context).colorScheme.surfaceContainerLow,
          child: SafeArea(
            top: false,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          '${s.scannerCapturedPages} (${state.scans.length})',
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: Theme.of(context).textTheme.labelLarge,
                        ),
                      ),
                      if (defaultTargetPlatform == TargetPlatform.android)
                        PopupMenuButton<ScanPageFormatKind>(
                          tooltip: s.scannerFormatTooltip(
                            s.scannerScanWideFormat,
                            _formatLabel(format),
                          ),
                          initialValue: format.kind,
                          onSelected: (kind) =>
                              _runOperation(() => _selectScanFormat(kind)),
                          itemBuilder: (context) => [
                            for (final kind in ScanPageFormatKind.values)
                              PopupMenuItem(
                                value: kind,
                                child: Text(_formatKindLabel(kind)),
                              ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                const Icon(Icons.aspect_ratio_outlined),
                                const SizedBox(width: 4),
                                Text(_shortFormatLabel(format)),
                                const Icon(Icons.arrow_drop_down),
                              ],
                            ),
                          ),
                        ),
                      IconButton(
                        tooltip: s.previewScan,
                        onPressed: () => _runOperation(() async {
                          await Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => DocumentView(
                                bytes: _assembleFileBytes(
                                  state.scans,
                                  forcePdf: true,
                                ).then((file) => file.bytes),
                              ),
                            ),
                          );
                        }),
                        icon: const Icon(Icons.visibility_outlined),
                      ),
                      IconButton(
                        tooltip: s.clearAll,
                        onPressed: () async {
                          final cubit = context.read<DocumentScannerCubit>();
                          if (await _confirmDelete(s.deleteAllScans) &&
                              mounted) {
                            await _runOperation(cubit.reset);
                          }
                        },
                        icon: const Icon(Icons.delete_sweep_outlined),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      Expanded(
                        child: OutlinedButton.icon(
                          label: Text(s.export),
                          onPressed: () => _runOperation(_onSaveToFile),
                          icon: const Icon(Icons.save_alt_outlined),
                        ),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: ConnectivityAwareActionWrapper(
                          offlineBuilder: (context, child) {
                            return FilledButton.icon(
                              label: Text(s.upload),
                              onPressed: null,
                              icon: const Icon(Icons.upload_outlined),
                            );
                          },
                          disabled: state.scans.isEmpty,
                          child: FilledButton.icon(
                            label: Text(s.upload),
                            onPressed: () => _runOperation(
                              () => _onPrepareDocumentUpload(
                                context,
                                state.scans,
                              ),
                            ),
                            icon: const Icon(Icons.upload_outlined),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Future<bool> _confirmDelete(String subject) async {
    final s = S.of(context)!;
    return await showDialog<bool>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(s.confirmDeletion),
            content: Text(subject),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(context, false),
                child: Text(s.cancel),
              ),
              FilledButton(
                style: FilledButton.styleFrom(
                  backgroundColor: Theme.of(context).colorScheme.error,
                ),
                onPressed: () => Navigator.pop(context, true),
                child: Text(s.delete),
              ),
            ],
          ),
        ) ??
        false;
  }

  String _formatLabel(ScanPageFormat format) => _formatKindLabel(format.kind);

  String _formatKindLabel(ScanPageFormatKind kind) {
    final s = S.of(context)!;
    return switch (kind) {
      ScanPageFormatKind.auto => s.scannerFormatAuto,
      ScanPageFormatKind.a4 => s.scannerFormatA4,
      ScanPageFormatKind.letter => s.scannerFormatLetter,
      ScanPageFormatKind.custom => s.scannerFormatCustom,
    };
  }

  String _shortFormatLabel(ScanPageFormat format) {
    final s = S.of(context)!;
    return switch (format.kind) {
      ScanPageFormatKind.auto => s.scannerFormatAutoShort,
      ScanPageFormatKind.a4 => s.scannerFormatA4,
      ScanPageFormatKind.letter => s.scannerFormatLetter,
      ScanPageFormatKind.custom => s.scannerFormatCustomShort,
    };
  }

  Future<ScanPageFormat?> _customPageFormat() async {
    final s = S.of(context)!;
    final current = context.read<DocumentScannerCubit>().scanFormat;
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

  Future<void> _selectScanFormat(ScanPageFormatKind kind) async {
    final format = switch (kind) {
      ScanPageFormatKind.auto => ScanPageFormat.auto,
      ScanPageFormatKind.a4 => ScanPageFormat.a4,
      ScanPageFormatKind.letter => ScanPageFormat.letter,
      ScanPageFormatKind.custom => await _customPageFormat(),
    };
    if (format == null || !mounted) return;
    final cubit = context.read<DocumentScannerCubit>();
    if (format == cubit.scanFormat) return;
    await cubit.setScanFormat(format);
    if (mounted) setState(() {});
  }

  Future<void> _onSaveToFile() async {
    final globalSettings = context.localStore.state.globalSettings;
    final fileName = await showDialog<String>(
      useRootNavigator: false,
      context: context,
      builder: (context) => const ExportScansDialog(),
    );
    if (fileName != null) {
      if (!mounted) return;
      final cubit = context.read<DocumentScannerCubit>();
      final file = await _assembleFileBytes(
        forcePdf: true,
        context.read<DocumentScannerCubit>().state.scans,
      );
      try {
        if (Platform.isAndroid && androidInfo!.version.sdkInt <= 29) {
          final isGranted = await askForPermission(Permission.storage);
          if (!isGranted) {
            if (!mounted) return;
            showSnackBar(
              context,
              S.of(context)!.scannerStoragePermissionRequired,
              action: SnackBarActionConfig(
                label: S.of(context)!.ok,
                onPressed: openAppSettings,
              ),
            );
            return;
          }
        }
        await cubit.saveToFile(
          file.bytes,
          "$fileName.pdf",
          globalSettings.preferredLocaleSubtag,
        );
      } catch (error) {
        if (!mounted) return;
        showGenericError(context, error);
      }
    }
  }

  Future<void> _openDocumentScanner(BuildContext context) async {
    final cubit = context.read<DocumentScannerCubit>();
    if (cubit.state.status == LoadingStatus.loading ||
        cubit.state.status == LoadingStatus.error) {
      return;
    }
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ScanCapturePage(
          initialPageCount: cubit.state.scans.length,
          initialFormat: cubit.scanFormat,
          onSave: (original, result) => cubit.saveScan(
            original: original,
            rendered: result.rendered,
            edit: result.edit,
          ),
        ),
      ),
    );
  }

  Future<void> _onPrepareDocumentUpload(
    BuildContext context,
    List<File> scans,
  ) async {
    final file = await _assembleFileBytes(
      scans,
      forcePdf:
          context.localStore.state.globalSettings.enforceSinglePagePdfUpload,
    );
    if (!context.mounted) return;
    final uploadResult = await DocumentUploadRoute(
      $extra: file.bytes,
      fileExtension: file.extension,
    ).push<DocumentUploadResult>(context);
    if (uploadResult?.success ?? false) {
      if (!context.mounted) return;
      // For paperless version older than 1.11.3, task id will always be null!
      await context.read<DocumentScannerCubit>().reset();
      // context
      //     .read<PendingTasksNotifier>()
      //     .listenToTaskChanges(uploadResult!.taskId!);
    }
  }

  Widget _buildEmptyState() {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: SingleChildScrollView(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                Icons.document_scanner_outlined,
                size: 72,
                color: Theme.of(context).colorScheme.primary,
              ),
              const SizedBox(height: 24),
              Text(
                S.of(context)!.noDocumentsScannedYet,
                textAlign: TextAlign.center,
                style: Theme.of(context).textTheme.titleMedium,
              ),
              const SizedBox(height: 24),
              FilledButton.icon(
                icon: const Icon(Icons.add_a_photo_outlined),
                label: Text(S.of(context)!.scanADocument),
                onPressed: () =>
                    _runOperation(() => _openDocumentScanner(context)),
              ),
              const SizedBox(height: 12),
              ConnectivityAwareActionWrapper(
                offlineBuilder: (context, child) => TextButton(
                  onPressed: null,
                  child: Text(S.of(context)!.uploadADocumentFromThisDevice),
                ),
                child: TextButton(
                  onPressed: () => _runOperation(_onUploadFromFilesystem),
                  child: Text(S.of(context)!.uploadADocumentFromThisDevice),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildImageGrid(List<File> scans, int revision) {
    if (scans.isEmpty) return _buildEmptyState();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: CustomScrollView(
        slivers: [
          SliverGrid.builder(
            itemCount: scans.length,
            gridDelegate: const SliverGridDelegateWithMaxCrossAxisExtent(
              maxCrossAxisExtent: 240,
              childAspectRatio: .65,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
            ),
            itemBuilder: (context, index) {
              return ScannedImageItem(
                key: ValueKey('${scans[index].path}:$revision'),
                file: scans[index],
                onEdit: () => _runOperation(() => _editScan(scans[index])),
                onRetake: defaultTargetPlatform == TargetPlatform.android
                    ? () => _runOperation(() => _retakeScan(scans[index]))
                    : null,
                onDelete: () async {
                  if (await _confirmDelete(
                        S.of(context)!.scannerPageLabel(index + 1),
                      ) &&
                      mounted) {
                    await _runOperation(
                      () => context.read<DocumentScannerCubit>().removeScan(
                        scans[index],
                      ),
                    );
                  }
                },
                onMoveEarlier: index == 0
                    ? null
                    : () => _runOperation(
                        () => context.read<DocumentScannerCubit>().moveScan(
                          scans[index],
                          -1,
                        ),
                      ),
                onMoveLater: index == scans.length - 1
                    ? null
                    : () => _runOperation(
                        () => context.read<DocumentScannerCubit>().moveScan(
                          scans[index],
                          1,
                        ),
                      ),
                index: index,
                totalNumberOfFiles: scans.length,
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 96)),
        ],
      ),
    );
  }

  Future<void> _editScan(File scan) async {
    final cubit = context.read<DocumentScannerCubit>();
    final original = await cubit.repository.readOriginal(scan);
    final edit = await cubit.repository.readEdit(scan);
    if (!mounted) return;
    await Navigator.of(context).push<ScanEditorResult>(
      MaterialPageRoute(
        builder: (_) => ScanEditorPage(
          original: original,
          initialEdit: edit,
          scanFormat: cubit.scanFormat,
          onSave: (result) => cubit.saveScan(
            original: original,
            rendered: result.rendered,
            edit: result.edit,
            replacing: scan,
          ),
        ),
      ),
    );
  }

  Future<void> _retakeScan(File scan) async {
    final cubit = context.read<DocumentScannerCubit>();
    final oldEdit = await cubit.repository.readEdit(scan);
    if (!mounted) return;
    final formatOverride = oldEdit?.formatOverride ?? false;
    final pageFormat = formatOverride ? oldEdit!.pageFormat : cubit.scanFormat;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ScanCapturePage(
          initialPageCount: max(0, cubit.state.scans.length - 1),
          initialFormat: pageFormat,
          initialFormatOverride: formatOverride,
          retake: true,
          onSave: (original, result) async {
            await cubit.saveScan(
              original: original,
              rendered: result.rendered,
              edit: result.edit,
              replacing: scan,
              replaceOriginal: true,
            );
          },
        ),
      ),
    );
  }

  Future<void> _onUploadFromFilesystem() async {
    FilePickerResult? result = await FilePicker.platform.pickFiles(
      type: FileType.custom,
      allowedExtensions: supportedFileExtensions
          .map((e) => e.replaceAll(".", ""))
          .toList(),
      withData: true,
      allowMultiple: false,
    );
    if (result?.files.single.path != null) {
      final path = result!.files.single.path!;
      final extension = p.extension(path);
      final filename = p.basenameWithoutExtension(path);
      File file = File(path);
      if (!supportedFileExtensions.contains(extension.toLowerCase())) {
        if (!mounted) return;
        showErrorMessage(
          context,
          const PaperlessApiException(ErrorCode.unsupportedFileFormat),
        );
        return;
      }
      if (!mounted) return;
      DocumentUploadRoute(
        $extra: file.readAsBytesSync(),
        filename: filename,
        title: filename,
        fileExtension: extension,
      ).push<DocumentUploadResult>(context);
      // if (uploadResult.success && uploadResult.taskId != null) {
      //   context
      //       .read<PendingTasksNotifier>()
      //       .listenToTaskChanges(uploadResult.taskId!);
      // }
    }
  }

  ///
  /// Returns the file bytes of either a single file or multiple images concatenated into a single pdf.
  ///
  Future<AssembledFile> _assembleFileBytes(
    final List<File> files, {
    bool forcePdf = false,
  }) async {
    assert(files.isNotEmpty);
    if (files.length == 1 && !forcePdf) {
      final ext = p.extension(files.first.path);
      return AssembledFile(ext, await files.first.readAsBytes());
    }
    final cubit = context.read<DocumentScannerCubit>();
    final pages = await Future.wait(files.map((file) => file.readAsBytes()));
    final formats = await Future.wait(
      files.map((file) async {
        final edit = await cubit.repository.readEdit(file);
        return (edit?.formatOverride ?? false)
            ? edit!.pageFormat
            : cubit.scanFormat;
      }),
    );
    return AssembledFile(
      '.pdf',
      await compute(assembleScanPdfRequest, ScanPdfRequest(pages, formats)),
    );
  }
}

class AssembledFile {
  final String extension;
  final Uint8List bytes;

  AssembledFile(this.extension, this.bytes);
}
