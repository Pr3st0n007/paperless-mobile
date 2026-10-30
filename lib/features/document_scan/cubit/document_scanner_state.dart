part of 'document_scanner_cubit.dart';

@freezed
abstract class DocumentScannerState with _$DocumentScannerState {
  const factory DocumentScannerState({
    @Default(LoadingStatus.initial) LoadingStatus status,
    @Default([]) List<File> scans,
    @Default(0) int revision,
  }) = _DocumentScannerState;
}
