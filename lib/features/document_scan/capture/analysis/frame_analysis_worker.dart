import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:paperless_mobile/features/document_scan/services/document_processor.dart';

/// Long-lived background isolate for live frame analysis. Spawning a fresh
/// isolate per frame (as `compute` does) costs noticeable time and memory
/// churn on low-end devices at 5–15 analyses per second.
class FrameAnalysisWorker {
  Isolate? _isolate;
  SendPort? _commands;
  ReceivePort? _responses;
  Future<void>? _starting;
  final _pending = <int, Completer<ScanFrameAnalysis>>{};
  int _nextId = 0;
  bool _closed = false;

  Future<ScanFrameAnalysis> analyze(Map<String, Object> frame) async {
    if (_closed) throw StateError('FrameAnalysisWorker is closed.');
    try {
      await (_starting ??= _start());
    } catch (_) {
      // Isolates unavailable (e.g. restricted test environments).
      return compute(DocumentProcessor.analyzeRgbFrame, frame);
    }
    final commands = _commands;
    if (_closed || commands == null) {
      throw StateError('FrameAnalysisWorker is closed.');
    }
    final id = _nextId++;
    final completer = _pending[id] = Completer<ScanFrameAnalysis>();
    commands.send((id, frame));
    return completer.future;
  }

  Future<void> _start() async {
    final responses = _responses = ReceivePort();
    final ready = Completer<SendPort>();
    responses.listen((message) {
      if (message is SendPort) {
        ready.complete(message);
        return;
      }
      final (id, result) = message as (int, Object);
      final completer = _pending.remove(id);
      if (completer == null) return;
      if (result is ScanFrameAnalysis) {
        completer.complete(result);
      } else {
        completer.completeError(result);
      }
    });
    _isolate = await Isolate.spawn(
      _main,
      responses.sendPort,
      debugName: 'scan-frame-analysis',
    );
    _commands = await ready.future;
  }

  static void _main(SendPort replies) {
    final commands = ReceivePort();
    replies.send(commands.sendPort);
    commands.listen((message) {
      final (id, frame) = message as (int, Map<String, Object>);
      try {
        replies.send((id, DocumentProcessor.analyzeRgbFrame(frame)));
      } on FormatException catch (error) {
        replies.send((id, error));
      } catch (error) {
        replies.send((id, StateError(error.toString())));
      }
    });
  }

  void close() {
    _closed = true;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _responses?.close();
    for (final completer in _pending.values) {
      completer.completeError(StateError('FrameAnalysisWorker is closed.'));
    }
    _pending.clear();
  }
}
