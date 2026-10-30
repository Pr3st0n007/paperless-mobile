import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_bloc/flutter_bloc.dart';
import 'package:freezed_annotation/freezed_annotation.dart';
import 'package:paperless_mobile/core/bloc/loading_status.dart';
import 'package:paperless_mobile/core/bloc/transient_error.dart';
import 'package:paperless_mobile/features/logging/data/logger.dart';
import 'package:paperless_mobile/core/service/file_service.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/services/scan_repository.dart';
import 'package:paperless_mobile/features/notifications/services/local_notification_service.dart';
import 'package:synchronized/synchronized.dart';

part 'document_scanner_cubit.freezed.dart';
part 'document_scanner_state.dart';

class DocumentScannerCubit extends Cubit<DocumentScannerState> {
  final LocalNotificationService _notificationService;
  final ScanRepository? _repository;
  final Lock _lock = Lock();
  ScanRepository get repository =>
      _repository ??
      ScanRepository(FileService.instance.temporaryScansDirectory);

  DocumentScannerCubit(this._notificationService, {ScanRepository? repository})
    : _repository = repository,
      super(const DocumentScannerState());

  Future<void> initialize() async {
    logger.fd(
      "Restoring scans...",
      className: runtimeType.toString(),
      methodName: "initialize",
    );
    emit(const DocumentScannerState(status: LoadingStatus.loading));
    try {
      final scans = await repository.restore();
      _emitScans(scans);
    } catch (error, stackTrace) {
      logger.fe(
        'Could not restore scans.',
        error: error,
        stackTrace: stackTrace,
      );
      emit(const DocumentScannerState(status: LoadingStatus.error));
      addError(TransientMessageError(message: error.toString()), stackTrace);
    }
  }

  void _emitScans(List<File> scans) => emit(
    DocumentScannerState(
      status: scans.isEmpty ? LoadingStatus.initial : LoadingStatus.loaded,
      scans: scans,
      revision: state.revision + 1,
    ),
  );

  Future<void> saveScan({
    required Uint8List original,
    required Uint8List rendered,
    required ScanEdit edit,
    File? replacing,
  }) => _lock.synchronized(() async {
    final scan = await repository.save(
      original: original,
      rendered: rendered,
      edit: edit,
      replacing: replacing,
    );
    final scans = replacing == null ? [...state.scans, scan] : [...state.scans];
    await repository.saveOrder(scans);
    await FileImage(scan).evict();
    _emitScans(scans);
  });

  Future<void> moveScan(File file, int offset) => _lock.synchronized(() async {
    final scans = [...state.scans];
    final index = scans.indexOf(file);
    final destination = index + offset;
    if (index < 0 || destination < 0 || destination >= scans.length) {
      throw RangeError('Invalid scan position.');
    }
    scans.removeAt(index);
    scans.insert(destination, file);
    await repository.saveOrder(scans);
    _emitScans(scans);
  });

  Future<void> removeScan(File file) => _lock.synchronized(() async {
    await repository.delete(file);
    final scans = state.scans.where((f) => f.path != file.path).toList();
    _emitScans(scans);
    await repository.saveOrder(scans);
    await FileImage(file).evict();
  });

  Future<void> reset() async {
    for (final file in [...state.scans]) {
      await removeScan(file);
    }
  }

  Future<void> saveToFile(
    Uint8List bytes,
    String fileName,
    String locale,
  ) async {
    try {
      var file = await FileService.instance.saveToFile(bytes, fileName);
      _notificationService.notifyFileSaved(
        filename: fileName,
        filePath: file.path,
        finished: true,
        locale: locale,
      );
    } on Exception catch (e) {
      addError(TransientMessageError(message: e.toString()));
    }
  }
}
