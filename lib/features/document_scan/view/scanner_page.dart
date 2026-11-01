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
import 'package:paperless_mobile/features/document_search/view/sliver_search_bar.dart';
import 'package:paperless_mobile/features/document_upload/view/document_upload_preparation_page.dart';
import 'package:paperless_mobile/features/documents/view/pages/document_view.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/connectivity_aware_action_wrapper.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';
import 'package:paperless_mobile/helpers/permission_helpers.dart';
import 'package:paperless_mobile/routing/routes/scanner_route.dart';
import 'package:path/path.dart' as p;
import 'package:permission_handler/permission_handler.dart';
import 'package:sliver_tools/sliver_tools.dart';

class ScannerPage extends StatefulWidget {
  const ScannerPage({super.key});

  @override
  State<ScannerPage> createState() => _ScannerPageState();
}

class _ScannerPageState extends State<ScannerPage>
    with SingleTickerProviderStateMixin {
  final SliverOverlapAbsorberHandle searchBarHandle =
      SliverOverlapAbsorberHandle();
  final SliverOverlapAbsorberHandle actionsHandle =
      SliverOverlapAbsorberHandle();

  final _scrollController = ScrollController();
  bool _working = false;

  @override
  void dispose() {
    _scrollController.dispose();
    searchBarHandle.dispose();
    actionsHandle.dispose();
    super.dispose();
  }

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
    return AbsorbPointer(
      absorbing: _working,
      child: SafeArea(
        top: true,
        child: Scaffold(
          drawer: const AppDrawer(),
          floatingActionButton: FloatingActionButton(
            heroTag: "fab_document_edit",
            onPressed: () => _runOperation(() => _openDocumentScanner(context)),
            child: const Icon(Icons.add_a_photo_outlined),
          ),
          body: Stack(
            children: [
              NestedScrollView(
                floatHeaderSlivers: true,
                headerSliverBuilder: (context, innerBoxIsScrolled) => [
                  SliverOverlapAbsorber(
                    handle: searchBarHandle,
                    sliver: SliverSearchBar(titleText: S.of(context)!.scanner),
                  ),
                  SliverOverlapAbsorber(
                    handle: actionsHandle,
                    sliver: SliverPinnedHeader(child: _buildActions()),
                  ),
                ],
                body: BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
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
      ),
    );
  }

  Widget _buildActions() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: SizedBox(
        height: kTextTabBarHeight,
        child: BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
          builder: (context, state) {
            return RawScrollbar(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 4),
              interactive: false,
              thumbVisibility: true,
              thickness: 2,
              radius: Radius.circular(2),
              controller: _scrollController,
              child: ListView(
                controller: _scrollController,
                scrollDirection: Axis.horizontal,
                children: [
                  SizedBox(width: 12),
                  if (defaultTargetPlatform == TargetPlatform.android)
                    BlocBuilder<DocumentScannerCubit, DocumentScannerState>(
                      builder: (context, _) {
                        final format = context
                            .read<DocumentScannerCubit>()
                            .scanFormat;
                        return PopupMenuButton<ScanPageFormatKind>(
                          tooltip: S.of(context)!.scannerScanWideFormat,
                          onSelected: (kind) => _runOperation(
                            () => _selectScanFormat(kind),
                          ),
                          itemBuilder: (context) => [
                            PopupMenuItem(
                              value: ScanPageFormatKind.auto,
                              child: Text(S.of(context)!.scannerFormatAuto),
                            ),
                            PopupMenuItem(
                              value: ScanPageFormatKind.a4,
                              child: Text(S.of(context)!.scannerFormatA4),
                            ),
                            PopupMenuItem(
                              value: ScanPageFormatKind.letter,
                              child: Text(S.of(context)!.scannerFormatLetter),
                            ),
                            PopupMenuItem(
                              value: ScanPageFormatKind.custom,
                              child: Text(S.of(context)!.scannerFormatCustom),
                            ),
                          ],
                          child: Padding(
                            padding: const EdgeInsets.symmetric(horizontal: 8),
                            child: Row(
                              children: [
                                const Icon(Icons.aspect_ratio_outlined),
                                const SizedBox(width: 4),
                                Text(
                                  '${S.of(context)!.scannerScanWideFormat}: ${_formatLabel(format)}',
                                ),
                              ],
                            ),
                          ),
                        );
                      },
                    ),
                  SizedBox(width: 8),
                  TextButton.icon(
                    label: Text(S.of(context)!.previewScan),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
                    ),
                    onPressed: state.scans.isNotEmpty
                        ? () => Navigator.of(context).push(
                            MaterialPageRoute(
                              builder: (context) => DocumentView(
                                bytes: _assembleFileBytes(
                                  state.scans,
                                  forcePdf: true,
                                ).then((file) => file.bytes),
                              ),
                            ),
                          )
                        : null,
                    icon: const Icon(Icons.visibility_outlined),
                  ),
                  SizedBox(width: 8),
                  TextButton.icon(
                    label: Text(S.of(context)!.clearAll),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
                    ),
                    onPressed: state.scans.isEmpty
                        ? null
                        : () => _runOperation(
                            context.read<DocumentScannerCubit>().reset,
                          ),
                    icon: const Icon(Icons.delete_sweep_outlined),
                  ),
                  SizedBox(width: 8),
                  ConnectivityAwareActionWrapper(
                    offlineBuilder: (context, child) {
                      return TextButton.icon(
                        label: Text(S.of(context)!.upload),
                        style: TextButton.styleFrom(
                          padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
                        ),
                        onPressed: null,
                        icon: const Icon(Icons.upload_outlined),
                      );
                    },
                    disabled: state.scans.isEmpty,
                    child: TextButton.icon(
                      label: Text(S.of(context)!.upload),
                      style: TextButton.styleFrom(
                        padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
                      ),
                      onPressed: () => _runOperation(
                        () => _onPrepareDocumentUpload(context, state.scans),
                      ),
                      icon: const Icon(Icons.upload_outlined),
                    ),
                  ),
                  SizedBox(width: 8),
                  TextButton.icon(
                    label: Text(S.of(context)!.export),
                    style: TextButton.styleFrom(
                      padding: const EdgeInsets.fromLTRB(5, 10, 5, 10),
                    ),
                    onPressed: state.scans.isEmpty
                        ? null
                        : () => _runOperation(_onSaveToFile),
                    icon: const Icon(Icons.save_alt_outlined),
                  ),
                  SizedBox(width: 12),
                ],
              ),
            );
          },
        ),
      ),
    );
  }

  String _formatLabel(ScanPageFormat format) {
    final s = S.of(context)!;
    return switch (format.kind) {
      ScanPageFormatKind.auto => s.scannerFormatAuto,
      ScanPageFormatKind.a4 => s.scannerFormatA4,
      ScanPageFormatKind.letter => s.scannerFormatLetter,
      ScanPageFormatKind.custom => s.scannerFormatCustom,
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
              "Please grant Paperless Mobile permissions to access your filesystem.",
              action: SnackBarActionConfig(
                label: "OK",
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
        padding: const EdgeInsets.all(8.0),
        child: Column(
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Text(
              S.of(context)!.noDocumentsScannedYet,
              textAlign: TextAlign.center,
            ),
            TextButton(
              child: Text(S.of(context)!.scanADocument),
              onPressed: () =>
                  _runOperation(() => _openDocumentScanner(context)),
            ),
            Text(S.of(context)!.or),
            ConnectivityAwareActionWrapper(
              offlineBuilder: (context, child) => TextButton(
                onPressed: null,
                child: Text(S.of(context)!.uploadADocumentFromThisDevice),
              ),
              child: TextButton(
                onPressed: _onUploadFromFilesystem,
                child: Text(S.of(context)!.uploadADocumentFromThisDevice),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildImageGrid(List<File> scans, int revision) {
    return Padding(
      padding: const EdgeInsets.all(8.0),
      child: CustomScrollView(
        slivers: [
          SliverOverlapInjector(handle: searchBarHandle),
          SliverOverlapInjector(handle: actionsHandle),
          SliverGrid.builder(
            itemCount: scans.length,
            gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 3,
              childAspectRatio: 1 / sqrt(2),
              crossAxisSpacing: 10,
              mainAxisSpacing: 10,
            ),
            itemBuilder: (context, index) {
              return ScannedImageItem(
                key: ValueKey('${scans[index].path}:$revision'),
                file: scans[index],
                onEdit: () => _runOperation(() => _editScan(scans[index])),
                onRetake: defaultTargetPlatform == TargetPlatform.android
                    ? () => _runOperation(() => _retakeScan(scans[index]))
                    : null,
                onDelete: () => _runOperation(
                  () => context.read<DocumentScannerCubit>().removeScan(
                    scans[index],
                  ),
                ),
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
    final pageFormat = formatOverride
        ? oldEdit!.pageFormat
        : cubit.scanFormat;
    var replaceNextPage = true;
    await Navigator.of(context, rootNavigator: true).push(
      MaterialPageRoute(
        builder: (_) => ScanCapturePage(
          initialPageCount: max(0, cubit.state.scans.length - 1),
          initialFormat: pageFormat,
          initialFormatOverride: formatOverride,
          onSave: (original, result) async {
            await cubit.saveScan(
              original: original,
              rendered: result.rendered,
              edit: result.edit,
              replacing: replaceNextPage ? scan : null,
              replaceOriginal: replaceNextPage,
            );
            replaceNextPage = false;
          },
        ),
      ),
    );
  }

  void _onUploadFromFilesystem() async {
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
    final pages = await Future.wait(files.map((file) => file.readAsBytes()));
    final cubit = context.read<DocumentScannerCubit>();
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
      await compute(
        assembleScanPdfRequest,
        ScanPdfRequest(pages, formats),
      ),
    );
  }
}

class AssembledFile {
  final String extension;
  final Uint8List bytes;

  AssembledFile(this.extension, this.bytes);
}
