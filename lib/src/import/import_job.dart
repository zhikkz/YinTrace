import 'dart:async';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/services.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../audio/audio_backend.dart';
import '../library/song.dart';
import '../library/song_repository.dart';
import '../separation/onnx_model.dart';
import '../separation/tensor_model.dart';
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

/// Runs the import pipeline in a background isolate so the UI stays fluid.
class ImportJob {
  ImportJob._(this._isolate, this._controller, this._commands, this._port);

  final Isolate _isolate;
  final StreamController<ImportEvent> _controller;
  final Completer<SendPort> _commands;
  final ReceivePort _port;

  Stream<ImportEvent> get events => _controller.stream;

  static Future<ImportJob> start(ImportRequest request, String songsRoot) async {
    final token = RootIsolateToken.instance;
    if (token == null) throw StateError('ImportJob must be started from the root isolate');
    final port = ReceivePort();
    final commands = Completer<SendPort>();
    final controller = StreamController<ImportEvent>();
    final isolate = await Isolate.spawn(
      _entry,
      [port.sendPort, token, request.toMap(), songsRoot],
      debugName: 'yintrace-import',
    );
    port.listen((msg) {
      if (msg is SendPort) {
        commands.complete(msg);
        return;
      }
      final m = msg as Map;
      switch (m['type']) {
        case 'progress':
          controller.add(ImportProgressEvent(ImportProgress.fromMap(m['progress'] as Map)));
        case 'done':
          controller.add(ImportDoneEvent(SongMeta.fromJson((m['song'] as Map).cast<String, dynamic>())));
          controller.close();
          port.close();
        case 'error':
          controller.add(ImportFailedEvent(m['message'] as String, cancelled: m['cancelled'] == true));
          controller.close();
          port.close();
      }
    });
    return ImportJob._(isolate, controller, commands, port);
  }

  /// Asks the job to stop at the next checkpoint (or kills the worker if it
  /// has not started yet).
  Future<void> cancel() async {
    if (_controller.isClosed) return;
    if (_commands.isCompleted) {
      (await _commands.future).send('cancel');
    } else {
      _isolate.kill(priority: Isolate.immediate);
      _controller.add(ImportFailedEvent('已取消', cancelled: true));
      await _controller.close();
      _port.close();
    }
  }

  static Future<void> _entry(List<Object?> args) async {
    final out = args[0] as SendPort;
    final token = args[1] as RootIsolateToken;
    final request = ImportRequest.fromMap(args[2] as Map<Object?, Object?>);
    final root = args[3] as String;
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final commands = ReceivePort();
    out.send(commands.sendPort);
    var cancelled = false;
    commands.listen((msg) {
      if (msg == 'cancel') cancelled = true;
    });

    final pipeline = ImportPipeline(
      audio: const NativeAudioBackend(),
      loadModel: (path, {required inputName, required outputName, coreML}) =>
          OnnxTensorModel.load(path, inputName: inputName, outputName: outputName, coreML: coreML),
      repository: SongRepository(Directory(root)),
      availableMemory: () => NativeAudio.availableMemory,
    );
    ImportStage? lastStage;
    var lastSent = DateTime.fromMillisecondsSinceEpoch(0);
    try {
      final song = await pipeline.run(request, isCancelled: () => cancelled, onProgress: (p) {
        final now = DateTime.now();
        // Start measuring a new stage before it loads the next model.
        if (p.stage == lastStage && now.difference(lastSent).inMilliseconds < 100 && p.stageFraction < 1) return;
        lastStage = p.stage;
        lastSent = now;
        out.send({'type': 'progress', 'progress': p.toMap()});
      });
      out.send({'type': 'done', 'song': song.toJson()});
    } on SeparationCancelled {
      out.send({'type': 'error', 'message': '已取消', 'cancelled': true});
    } catch (e) {
      out.send({'type': 'error', 'message': e.toString()});
    } finally {
      commands.close();
    }
  }
}
