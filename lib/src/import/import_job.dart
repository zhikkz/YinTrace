import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../analysis/mandarin_readings.dart';
import '../audio/audio_backend.dart';
import '../library/song.dart';
import '../library/song_repository.dart';
import '../separation/onnx_model.dart';
import '../separation/tensor_model.dart';
import 'import_model_pool.dart';
import 'import_pipeline.dart';

/// Events emitted by a running [ImportJob].
sealed class ImportEvent {}

class ImportProgressEvent extends ImportEvent {
  ImportProgressEvent(this.progress);
  final ImportProgress progress;
}

class ImportDoneEvent extends ImportEvent {
  ImportDoneEvent(this.song);
  final SongMeta song;
}

class ImportFailedEvent extends ImportEvent {
  ImportFailedEvent(this.message, {this.cancelled = false});
  final String message;
  final bool cancelled;
}

/// Handle for a single import, whether run alone or by the shared worker.
class ImportJob {
  ImportJob._(this.events, this._cancel);

  final Stream<ImportEvent> events;
  final void Function() _cancel;

  /// Runs a single import on its own worker (also used by the benchmark).
  static Future<ImportJob> start(ImportRequest request, String songsRoot) async {
    final worker = await ImportWorker._spawn(songsRoot, shared: false);
    return worker.startJob(request);
  }

  /// Asks the job to stop at the next checkpoint.
  Future<void> cancel() async => _cancel();
}

/// Runs the queue's active imports in one isolate so their model sessions
/// can be reused and synchronous audio processing stays off the UI isolate.
class ImportWorker {
  ImportWorker._(this._port, this._shared) {
    _port.listen(_onMessage);
  }

  final ReceivePort _port;
  final bool _shared;
  final _exited = Completer<void>();
  final _jobs = <int, StreamController<ImportEvent>>{};
  final _pendingCommands = <Object>[];
  SendPort? _commands;
  int _nextId = 0;
  bool _closing = false;
  String? _failure;

  bool get isClosed => _closing;

  static Future<ImportWorker> start(String songsRoot) => _spawn(songsRoot, shared: true);

  static Future<ImportWorker> _spawn(String songsRoot, {required bool shared}) async {
    final token = RootIsolateToken.instance;
    if (token == null) throw StateError('ImportWorker must be started from the root isolate');
    final port = ReceivePort();
    try {
      await Isolate.spawn(
        _entry,
        (port.sendPort, token, songsRoot, shared),
        onError: port.sendPort,
        onExit: port.sendPort,
        debugName: 'yintrace-import',
      );
      return ImportWorker._(port, shared);
    } catch (_) {
      port.close();
      rethrow;
    }
  }

  ImportJob startJob(ImportRequest request) {
    if (isClosed) throw StateError('导入进程已停止');
    final id = _nextId++;
    final controller = _jobs[id] = StreamController<ImportEvent>();
    _send((id, request));
    return ImportJob._(controller.stream, () {
      if (_jobs.containsKey(id)) _send(id);
    });
  }

  /// Stops any outstanding imports and releases the worker's native models.
  Future<void> close() {
    if (!_closing) {
      _closing = true;
      _send('close');
    }
    return _exited.future;
  }

  void _send(Object message) {
    final commands = _commands;
    if (commands == null) {
      _pendingCommands.add(message);
    } else {
      commands.send(message);
    }
  }

  void _onMessage(dynamic message) {
    switch (message) {
      case ('mandarinTables', final SendPort reply):
        MandarinReadings.bundledTables().then<void>(reply.send, onError: (Object e) => reply.send('$e'));
      case final SendPort commands:
        _commands = commands;
        for (final pending in _pendingCommands) {
          commands.send(pending);
        }
        _pendingCommands.clear();
      case (final int id, final ImportEvent event):
        final controller = _jobs[id];
        if (controller == null) return;
        controller.add(event);
        if (event is! ImportProgressEvent) {
          _jobs.remove(id);
          unawaited(controller.close());
          if (!_shared) unawaited(close());
        }
      case [final String error, _]:
        _failure = error;
        _closing = true;
      case null:
        _closing = true;
        final failure = _failure;
        for (final controller in _jobs.values) {
          controller.add(ImportFailedEvent(failure == null ? '导入进程意外停止' : '导入进程意外停止：$failure'));
          unawaited(controller.close());
        }
        _jobs.clear();
        _pendingCommands.clear();
        _port.close();
        _exited.complete();
    }
  }

  static void _entry((SendPort, RootIsolateToken, String, bool) args) {
    final (out, token, root, shared) = args;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    MandarinReadings.initializeWorker(() async {
      final reply = ReceivePort();
      try {
        out.send(('mandarinTables', reply.sendPort));
        final tables = await reply.first;
        if (tables is List<String>) return tables;
        throw StateError('$tables');
      } finally {
        reply.close();
      }
    });
    final pool = shared ? ImportModelPool() : null;
    final pipeline = ImportPipeline(
      audio: const NativeAudioBackend(),
      loadModel: (path, {required inputName, required outputName, coreML}) =>
          OnnxTensorModel.load(path, inputName: inputName, outputName: outputName, coreML: coreML),
      repository: SongRepository(Directory(root)),
      availableMemory: () => NativeAudio.availableMemory,
      sharedModels: pool,
    );

    final commands = ReceivePort();
    final active = <int, _ImportCancellation>{};
    var closing = false;

    Future<void> finishIfIdle() async {
      if (!closing || active.isNotEmpty) return;
      commands.close();
      await pool?.close();
      // BackgroundIsolateBinaryMessenger keeps a port open; exit after all
      // plugin operations, including ONNX session disposal, are complete.
      Isolate.exit();
    }

    Future<void> run(int id, ImportRequest request) async {
      final state = active[id] = _ImportCancellation();
      ImportStage? lastStage;
      var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
      try {
        final song = await pipeline.run(request, isCancelled: () => state.cancelled, onProgress: (p) {
          final now = DateTime.now();
          if (p.stage == lastStage && now.difference(lastSent).inMilliseconds < 100 && p.stageFraction < 1) return;
          lastStage = p.stage;
          lastSent = now;
          out.send((id, ImportProgressEvent(p)));
        });
        out.send((id, ImportDoneEvent(song)));
      } on SeparationCancelled {
        out.send((id, ImportFailedEvent('已取消', cancelled: true)));
      } catch (e) {
        out.send((id, ImportFailedEvent(e.toString())));
      } finally {
        active.remove(id);
        await finishIfIdle();
      }
    }

    commands.listen((message) {
      switch (message) {
        case (final int id, final ImportRequest request):
          unawaited(run(id, request));
        case final int id:
          active[id]?.cancelled = true;
          pool?.cancelPending();
        case 'close':
          closing = true;
          for (final state in active.values) {
            state.cancelled = true;
          }
          pool?.cancelPending();
          unawaited(finishIfIdle());
      }
    });
    out.send(commands.sendPort);
  }
}

class _ImportCancellation {
  bool cancelled = false;
}
