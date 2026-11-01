import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:camera/camera.dart';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:flutter/services.dart';
import 'package:paperless_mobile/features/document_scan/capture/analysis/camera_frame_converter.dart';
import 'package:paperless_mobile/features/document_scan/capture/analysis/live_scan_analyzer.dart';
import 'package:paperless_mobile/features/document_scan/capture/auto_capture_controller.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/camera_permission_gateway.dart';
import 'package:paperless_mobile/features/document_scan/capture/camera/scan_camera_session.dart';
import 'package:paperless_mobile/features/document_scan/capture/capture_draft.dart';
import 'package:paperless_mobile/features/document_scan/capture/scan_capture_preferences.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_edit.dart';
import 'package:paperless_mobile/features/document_scan/model/scan_page_format.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/camera_status_view.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/camera_viewport.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/capture_controls.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/captured_page_sheet.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/captured_pages_tray.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/document_overlay.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/guidance_chip.dart';
import 'package:paperless_mobile/features/document_scan/view/capture/scanner_settings_sheet.dart';
import 'package:paperless_mobile/features/document_scan/view/scan_editor_page.dart';
import 'package:paperless_mobile/generated/l10n/app_localizations.dart';
import 'package:paperless_mobile/helpers/message_helpers.dart';

/// Multi-page capture screen.
///
/// This widget only orchestrates; camera lifecycle lives in
/// [ScanCameraSession], live detection in [LiveScanAnalyzer], auto-capture
/// timing in [AutoCaptureController] and unsaved pages in [CaptureDraft].
class ScanCapturePage extends StatefulWidget {
  final Future<void> Function(Uint8List original, ScanEditorResult result)
  onSave;
  final int initialPageCount;
  final ScanPageFormat initialFormat;
  final bool initialFormatOverride;
  final bool retake;
  final CameraPermissionGateway permissions;
  final ScanCapturePreferencesStore preferencesStore;

  const ScanCapturePage({
    super.key,
    required this.onSave,
    required this.initialPageCount,
    required this.initialFormat,
    this.initialFormatOverride = false,
    this.retake = false,
    this.permissions = const PlatformCameraPermissionGateway(),
    this.preferencesStore = const ScanCapturePreferencesStore(),
  });

  @override
  State<ScanCapturePage> createState() => _ScanCapturePageState();
}

class _ScanCapturePageState extends State<ScanCapturePage>
    with WidgetsBindingObserver, TickerProviderStateMixin {
  late final _session = ScanCameraSession(permissions: widget.permissions);
  final _autoCapture = AutoCaptureController();
  late final _analyzer = LiveScanAnalyzer(
    autoCapture: _autoCapture,
    onUnsupportedFormat: _session.markLiveAnalysisUnavailable,
  );
  late final _draft = CaptureDraft(
    format: widget.initialFormat,
    formatOverride: widget.initialFormatOverride,
  );
  late final AnimationController _countdown;
  late final AnimationController _flash;

  ScanCapturePreferences _prefs = const ScanCapturePreferences();
  bool _showTips = false;
  bool _busy = false;
  bool _backgrounded = false;
  int? _retakeIndex;
  int _savedCount = 0;
  (int, int)? _saveProgress;
  CapturePhase _lastPhase = CapturePhase.searching;
  ScaffoldFeatureController<SnackBar, SnackBarClosedReason>? _undoSnackBar;

  bool get _isAndroid => defaultTargetPlatform == TargetPlatform.android;
  int get _pageCount => widget.initialPageCount + _draft.length + _savedCount;

  @override
  void initState() {
    super.initState();
    _countdown = AnimationController(vsync: this);
    _flash = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 280),
    );
    WidgetsBinding.instance.addObserver(this);
    _draft.addListener(_onDraftChanged);
    _analyzer.readiness.addListener(_onReadiness);
    unawaited(_session.setFrameListener(_isAndroid ? _onFrame : null));
    unawaited(_loadPreferences());
    unawaited(_session.open());
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _undoSnackBar?.close();
    _draft.removeListener(_onDraftChanged);
    _analyzer.readiness.removeListener(_onReadiness);
    _analyzer.dispose();
    _countdown.dispose();
    _flash.dispose();
    unawaited(_session.dispose());
    unawaited(_draft.cleanup().catchError((Object _) {}));
    _draft.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    switch (state) {
      case AppLifecycleState.resumed:
        final status = _session.state.value.status;
        if (_backgrounded ||
            status == ScanCameraStatus.permissionRequired ||
            status == ScanCameraStatus.permissionPermanentlyDenied) {
          _backgrounded = false;
          _analyzer.invalidate(resetAutoCapture: true);
          unawaited(_session.open(askPermission: false));
        }
      // Inactive also fires for permission dialogs and the notification
      // shade; releasing the camera there caused restart races.
      case AppLifecycleState.hidden || AppLifecycleState.paused:
        if (!_backgrounded) {
          _backgrounded = true;
          unawaited(_session.close());
        }
      case AppLifecycleState.inactive || AppLifecycleState.detached:
        break;
    }
  }

  Future<void> _loadPreferences() async {
    try {
      final prefs = await widget.preferencesStore.load();
      if (!mounted) return;
      _applyPreferences(prefs);
      setState(() => _showTips = _isAndroid && !prefs.tipsSeen);
      _updateSuspension();
    } catch (_) {
      // Defaults are fine when preferences are unavailable.
    }
  }

  void _applyPreferences(ScanCapturePreferences prefs) {
    _prefs = prefs;
    _autoCapture
      ..enabled = prefs.autoCapture
      ..speed = prefs.speed;
  }

  void _updatePreferences(ScanCapturePreferences prefs) {
    setState(() => _applyPreferences(prefs));
    _analyzer.invalidate();
    unawaited(widget.preferencesStore.save(prefs).catchError((Object _) {}));
  }

  void _updateSuspension() {
    _autoCapture.suspended =
        widget.retake || _retakeIndex != null || _showTips || _busy;
  }

  void _onDraftChanged() {
    if (mounted) setState(() {});
  }

  void _onFrame(CameraImage frame) {
    final controller = _session.controller;
    if (controller == null || _busy || !mounted) return;
    _analyzer.onFrame(
      frame,
      CameraFrameConverter.rotationFor(
        controller.description,
        controller.value.deviceOrientation,
      ),
    );
  }

  void _onReadiness() {
    final readiness = _analyzer.readiness.value;
    _syncCountdown(readiness);
    final previous = _lastPhase;
    _lastPhase = readiness.phase;
    final becameReady =
        (readiness.phase == CapturePhase.ready ||
            readiness.phase == CapturePhase.holding) &&
        previous != CapturePhase.ready &&
        previous != CapturePhase.holding;
    if (becameReady && _prefs.haptics) HapticFeedback.selectionClick();
    if (readiness.shouldCapture && !_busy) unawaited(_capture());
  }

  /// Animates the ring smoothly between analysis results and resyncs only
  /// when it drifts, so the countdown never appears to stutter.
  void _syncCountdown(CaptureReadiness readiness) {
    switch (readiness.phase) {
      case CapturePhase.holding:
        final drift = (_countdown.value - readiness.progress).abs();
        if (!_countdown.isAnimating || drift > 0.1) {
          _countdown.value = readiness.progress;
          if (readiness.remaining > Duration.zero) {
            _countdown.animateTo(1, duration: readiness.remaining);
          }
        }
      case CapturePhase.triggered:
        _countdown.value = 1;
      default:
        if (_countdown.value > 0) {
          _countdown.animateBack(
            0,
            duration: const Duration(milliseconds: 150),
          );
        }
    }
  }

  void _setBusy(bool busy) {
    if (!mounted) return;
    setState(() => _busy = busy);
    _updateSuspension();
  }

  Future<void> _capture() async {
    if (_busy || !_session.state.value.isReady) return;
    final corners = _analyzer.lastCorners;
    final fingerprint = _analyzer.lastFingerprint;
    _setBusy(true);
    _analyzer.invalidate();
    try {
      final bytes = await _session.takePicture();
      if (!mounted) return;
      _shutterFeedback();
      await _acceptImage(bytes);
      _autoCapture.pageCaptured(corners: corners, fingerprint: fingerprint);
    } catch (error, stackTrace) {
      _autoCapture.captureAborted();
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      _setBusy(false);
      _analyzer.invalidate();
    }
  }

  Future<void> _import() async {
    if (_busy) return;
    _setBusy(true);
    await _session.pauseAnalysis();
    try {
      final selection = await FilePicker.platform.pickFiles(
        type: FileType.custom,
        allowedExtensions: const ['jpg', 'jpeg', 'png'],
        withData: true,
      );
      if (selection == null || !mounted) return;
      final selected = selection.files.single;
      var bytes = selected.bytes;
      if (bytes == null && selected.path != null) {
        bytes = await File(selected.path!).readAsBytes();
      }
      if (bytes == null) {
        throw const FileSystemException('Unable to read selected image.');
      }
      await _acceptImage(Uint8List.fromList(bytes));
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      _setBusy(false);
      _analyzer.invalidate();
      await _session.resumeAnalysis();
    }
  }

  /// Android keeps a multi-page draft. iOS has no live detection and reviews
  /// each page in the editor straight away.
  Future<void> _acceptImage(Uint8List original) async {
    if (!_isAndroid || widget.retake) {
      await _reviewSinglePage(original);
      return;
    }
    final replacing = _retakeIndex;
    await _draft.addCapture(original, replaceIndex: replacing);
    if (!mounted) return;
    setState(() => _retakeIndex = null);
    _updateSuspension();
    final number = replacing == null ? _draft.length : replacing + 1;
    SemanticsService.announce(
      S.of(context)!.scannerPageCaptured(number),
      Directionality.of(context),
    );
  }

  Future<void> _reviewSinglePage(Uint8List original) async {
    final analysis = await compute(DocumentProcessor.analyze, original);
    if (!mounted) return;
    final result = await Navigator.of(context).push<ScanEditorResult>(
      MaterialPageRoute(
        builder: (_) => ScanEditorPage(
          original: original,
          initialEdit: ScanEdit(
            corners: analysis.detectedCorners ?? ScanEdit.fullPage,
            pageFormat: widget.initialFormat,
            formatOverride: widget.initialFormatOverride,
          ),
          scanFormat: widget.initialFormat,
          onSave: (result) => widget.onSave(original, result),
        ),
      ),
    );
    if (mounted && result != null) {
      if (widget.retake) {
        Navigator.pop(context);
      } else {
        setState(() => _savedCount++);
      }
    }
  }

  void _shutterFeedback() {
    if (_prefs.haptics) HapticFeedback.mediumImpact();
    if (!MediaQuery.of(context).disableAnimations) _flash.forward(from: 0);
  }

  Future<void> _openPage(int index) async {
    if (_busy || index >= _draft.length) return;
    final action = await showCapturedPageSheet(
      context,
      page: _draft.pages[index],
      index: index,
      canRetake: _isAndroid,
    );
    if (!mounted || action == null) return;
    switch (action) {
      case CapturedPageAction.edit:
        await _editPage(index);
      case CapturedPageAction.retake:
        setState(() => _retakeIndex = index);
        _updateSuspension();
      case CapturedPageAction.delete:
        _deletePage(index);
    }
  }

  Future<void> _editPage(int index) async {
    _setBusy(true);
    await _session.pauseAnalysis();
    try {
      final page = _draft.pages[index];
      final original = await page.originalFile.readAsBytes();
      if (!mounted) return;
      final result = await Navigator.of(context).push<ScanEditorResult>(
        MaterialPageRoute(
          builder: (_) => ScanEditorPage(
            original: original,
            initialEdit: page.edit,
            scanFormat: widget.initialFormat,
          ),
        ),
      );
      if (result != null) await _draft.applyEdit(index, result.edit);
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    } finally {
      _setBusy(false);
      _analyzer.invalidate();
      await _session.resumeAnalysis();
    }
  }

  void _deletePage(int index) {
    final s = S.of(context)!;
    final page = _draft.removeAt(index);
    setState(() {
      if (_retakeIndex == index) {
        _retakeIndex = null;
      } else if (_retakeIndex != null && _retakeIndex! > index) {
        _retakeIndex = _retakeIndex! - 1;
      }
    });
    _updateSuspension();
    final messenger = ScaffoldMessenger.of(context)..hideCurrentSnackBar();
    final snackBar = _undoSnackBar = messenger.showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        content: Text(s.scannerPageDeleted(index + 1)),
        action: SnackBarAction(
          label: s.undo,
          onPressed: () {
            if (mounted) _draft.restore(index, page);
          },
        ),
      ),
    );
    snackBar.closed.then((reason) {
      if (identical(_undoSnackBar, snackBar)) _undoSnackBar = null;
      if (reason != SnackBarClosedReason.action || !mounted) {
        unawaited(_draft.discard(page));
      }
    });
  }

  Future<void> _finish() async {
    if (_busy) return;
    if (_draft.isEmpty) {
      Navigator.of(context).pop();
      return;
    }
    _setBusy(true);
    await _session.pauseAnalysis();
    try {
      await _draft.commit(
        (original, result) async {
          await widget.onSave(original, result);
          _savedCount++;
        },
        onProgress: (done, total) {
          if (mounted) setState(() => _saveProgress = (done, total));
        },
      );
      await _draft.cleanup();
      if (mounted) Navigator.of(context).pop();
    } catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
      await _session.resumeAnalysis();
    } finally {
      if (mounted) setState(() => _saveProgress = null);
      _setBusy(false);
    }
  }

  Future<void> _confirmLeave() async {
    if (_busy) return;
    final s = S.of(context)!;
    final choice = await showDialog<_LeaveChoice>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(s.scannerDiscardTitle),
        content: Text(s.scannerDiscardBody(_draft.length)),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, _LeaveChoice.discard),
            child: Text(s.discard),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: Text(s.scannerKeepScanning),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, _LeaveChoice.save),
            child: Text(s.scannerSavePages),
          ),
        ],
      ),
    );
    if (!mounted) return;
    switch (choice) {
      case _LeaveChoice.discard:
        await _draft.cleanup();
        if (mounted) Navigator.of(context).pop();
      case _LeaveChoice.save:
        await _finish();
      case null:
        break;
    }
  }

  Future<void> _toggleTorch() async {
    try {
      await _session.setTorch(!_session.state.value.torchOn);
    } on CameraException catch (error, stackTrace) {
      if (mounted) showGenericError(context, error, stackTrace);
    }
  }

  Future<void> _focus(Offset point) async {
    if (_busy) return;
    try {
      await _session.focusAt(point);
    } on CameraException {
      // Focus is best effort; continuous autofocus stays active.
    }
  }

  void _dismissTips() {
    setState(() => _showTips = false);
    _updateSuspension();
    _updatePreferences(_prefs.copyWith(tipsSeen: true));
  }

  void _openSettings() {
    showScannerSettingsSheet(
      context,
      initial: _prefs,
      onChanged: _updatePreferences,
      onShowTips: () {
        setState(() => _showTips = true);
        _updateSuspension();
      },
    );
  }

  ThemeData _cameraTheme(BuildContext context) {
    final base = Theme.of(context);
    return ThemeData(
      colorScheme: ColorScheme.fromSeed(
        seedColor: base.colorScheme.primary,
        brightness: Brightness.dark,
      ),
      fontFamily: base.textTheme.bodyMedium?.fontFamily,
      scaffoldBackgroundColor: Colors.black,
      appBarTheme: const AppBarTheme(
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        surfaceTintColor: Colors.transparent,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Theme(
      data: _cameraTheme(context),
      child: Builder(builder: _buildScreen),
    );
  }

  Widget _buildScreen(BuildContext context) {
    final s = S.of(context)!;
    return ValueListenableBuilder<ScanCameraState>(
      valueListenable: _session.state,
      builder: (context, camera, _) {
        final ready = camera.isReady;
        return PopScope(
          canPop: !_busy && _draft.isEmpty,
          onPopInvokedWithResult: (didPop, _) {
            if (!didPop) unawaited(_confirmLeave());
          },
          child: Scaffold(
            appBar: AppBar(
              title: Text(widget.retake ? s.scannerRetakeCaptured : s.scan),
              actions: [
                IconButton(
                  tooltip: s.scannerTorch,
                  isSelected: camera.torchOn,
                  onPressed: _busy || !ready ? null : _toggleTorch,
                  icon: const Icon(Icons.flash_off),
                  selectedIcon: const Icon(Icons.flash_on),
                ),
                if (_isAndroid)
                  IconButton(
                    tooltip: s.scannerSettingsTitle,
                    onPressed: _busy ? null : _openSettings,
                    icon: const Icon(Icons.tune),
                  ),
              ],
            ),
            body: SafeArea(
              top: false,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final landscape =
                      constraints.maxWidth >= 600 &&
                      constraints.maxWidth > constraints.maxHeight;
                  final tray = _isAndroid
                      ? CapturedPagesTray(
                          pages: _draft.pages,
                          retakeIndex: _retakeIndex,
                          onOpen: _busy ? (_) {} : _openPage,
                        )
                      : const SizedBox.shrink();
                  if (landscape) {
                    return Row(
                      children: [
                        Expanded(child: _buildViewport(context, camera)),
                        SizedBox(
                          width: 240,
                          child: SingleChildScrollView(
                            child: Column(
                              children: [tray, _buildControls(context, camera)],
                            ),
                          ),
                        ),
                      ],
                    );
                  }
                  return Column(
                    children: [
                      Expanded(child: _buildViewport(context, camera)),
                      tray,
                      _buildControls(context, camera),
                    ],
                  );
                },
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildViewport(BuildContext context, ScanCameraState camera) {
    final s = S.of(context)!;
    final controller = camera.controller;
    final saving = _saveProgress;
    return Stack(
      fit: StackFit.expand,
      children: [
        if (camera.isReady && controller != null)
          CameraViewport(
            controller: controller,
            onFocus: _focus,
            overlayBuilder: (context, source) => _isAndroid
                ? ValueListenableBuilder<CaptureReadiness>(
                    valueListenable: _analyzer.readiness,
                    builder: (context, readiness, _) => DocumentOverlay(
                      readiness: readiness,
                      sourceSize: source,
                      countdown: _countdown,
                    ),
                  )
                : const IgnorePointer(
                    child: CustomPaint(painter: _A4GuidePainter()),
                  ),
          )
        else
          CameraStatusView(
            status: camera.status,
            onRequestPermission: () => _session.open(),
            onOpenSettings: widget.permissions.openSettings,
            onRetry: () => _session.open(),
            onImport: _busy ? null : _import,
          ),
        if (camera.isReady)
          Positioned(
            top: 12,
            left: 16,
            right: 16,
            child: Center(child: _buildStatusLine(context, camera)),
          ),
        IgnorePointer(
          child: FadeTransition(
            opacity: TweenSequence([
              TweenSequenceItem(tween: Tween(begin: 0.0, end: 0.7), weight: 1),
              TweenSequenceItem(tween: Tween(begin: 0.7, end: 0.0), weight: 3),
            ]).animate(_flash),
            child: const ColoredBox(color: Colors.white),
          ),
        ),
        if (_showTips && camera.isReady)
          Center(child: ScanningTipsCard(onDismiss: _dismissTips)),
        if (saving != null)
          ColoredBox(
            color: Colors.black.withValues(alpha: 0.7),
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(
                    value: saving.$2 == 0 ? null : saving.$1 / saving.$2,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    s.scannerSaving(min(saving.$1 + 1, saving.$2), saving.$2),
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }

  Widget _buildStatusLine(BuildContext context, ScanCameraState camera) {
    final s = S.of(context)!;
    final retaking = _retakeIndex;
    if (retaking != null) {
      return InputChip(
        avatar: const Icon(Icons.refresh, size: 18),
        label: Text(s.scannerRetaking(retaking + 1)),
        onDeleted: () {
          setState(() => _retakeIndex = null);
          _updateSuspension();
        },
        deleteButtonTooltipMessage: s.scannerCancelRetake,
      );
    }
    if (!_isAndroid) {
      return GuidanceChip(
        guidance: CaptureGuidance.searching,
        message: s.scannerCaptureHintIos,
      );
    }
    return ValueListenableBuilder<CaptureReadiness>(
      valueListenable: _analyzer.readiness,
      builder: (context, readiness, _) => GuidanceChip(
        guidance: readiness.guidance,
        message: camera.liveAnalysisAvailable ? null : s.scannerLiveUnavailable,
      ),
    );
  }

  Widget _buildControls(BuildContext context, ScanCameraState camera) {
    final s = S.of(context)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          if (_isAndroid && camera.liveAnalysisAvailable && !widget.retake) ...[
            AutoCaptureToggle(
              enabled: _prefs.autoCapture,
              speed: _prefs.speed,
              onChanged: _busy || _retakeIndex != null
                  ? null
                  : (value) =>
                        _updatePreferences(_prefs.copyWith(autoCapture: value)),
            ),
            const SizedBox(height: 16),
          ],
          Row(
            children: [
              Expanded(
                child: Align(
                  child: IconButton(
                    iconSize: 28,
                    tooltip: s.scannerImportImage,
                    onPressed: _busy ? null : _import,
                    icon: const Icon(Icons.photo_library_outlined),
                  ),
                ),
              ),
              ShutterButton(
                onPressed: _busy || !camera.isReady ? null : _capture,
                countdown: _countdown,
                busy: _busy && _saveProgress == null,
                retaking: widget.retake || _retakeIndex != null,
              ),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.only(left: 8),
                  child: widget.retake
                      ? IconButton(
                          tooltip: s.cancel,
                          onPressed: _busy
                              ? null
                              : () => Navigator.maybePop(context),
                          icon: const Icon(Icons.close),
                        )
                      : FilledButton.tonal(
                          onPressed: _busy || _pageCount == 0 ? null : _finish,
                          child: FittedBox(
                            fit: BoxFit.scaleDown,
                            child: Text('${s.done} ($_pageCount)'),
                          ),
                        ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

enum _LeaveChoice { discard, save }

class _A4GuidePainter extends CustomPainter {
  const _A4GuidePainter();

  @override
  void paint(Canvas canvas, Size size) {
    final landscape = size.width > size.height;
    final ratio = landscape ? sqrt2 : 1 / sqrt2;
    var width = size.width * .86;
    var height = width / ratio;
    if (height > size.height * .86) {
      height = size.height * .86;
      width = height * ratio;
    }
    canvas.drawRRect(
      RRect.fromRectAndRadius(
        Rect.fromCenter(
          center: size.center(Offset.zero),
          width: width,
          height: height,
        ),
        const Radius.circular(8),
      ),
      Paint()
        ..color = Colors.white70
        ..strokeWidth = 2
        ..style = PaintingStyle.stroke,
    );
  }

  @override
  bool shouldRepaint(_A4GuidePainter oldDelegate) => false;
}
