import 'dart:async';

import 'package:flutter/foundation.dart';

import '../app/picked_files.dart';
import '../app/screen_awake.dart';
import '../library/song.dart';
import '../library/song_package.dart';
import 'import_job.dart';
import 'import_pipeline.dart';
import 'vocal_acceleration.dart';

enum ImportQueueStatus {
  queued,
  running,
  cancelling,
  completed,
  failed,
  cancelled,
}

class ImportQueueEntry {
  ImportQueueEntry._audio(ImportRequest request)
    : title = request.title.trim().isEmpty ? '未命名歌曲' : request.title.trim(),
      _request = request,
      _package = null;

  ImportQueueEntry._package(this.title, String path, bool background)
    : _request = null,
      _package = (path: path, background: background);

  final String title;
  ImportRequest? _request;
  ({String path, bool background})? _package;
  ImportQueueStatus _status = ImportQueueStatus.queued;
  ImportProgress? _progress;
  SongMeta? _song;
  String? _error;
  DateTime? _startedAt;
  DateTime? _finishedAt;
  Future<void> Function()? _cancelJob;

  ImportQueueStatus get status => _status;
  ImportProgress? get progress => _progress;
  SongMeta? get song => _song;
  String? get error => _error;
  DateTime? get startedAt => _startedAt;
  DateTime? get finishedAt => _finishedAt;
  bool get canCancel =>
      status == ImportQueueStatus.queued ||
      (status == ImportQueueStatus.running && _request != null);

  bool get _usesDownloadedModels =>
      _request?.mdxModelPath != null ||
      _request?.vrModelPath != null ||
      _request?.hubertFaPath != null;

  Set<String> get _inputPaths => {
    if (_request case final request?) ...{
      request.audioPath,
      ?request.accompanimentPath,
    },
    if (_package case final package?) package.path,
  };
}

typedef ImportTask = ({
  Stream<ImportEvent> events,
  Future<void> Function() cancel,
});

/// Owns imports and their picked files for the lifetime of the app, independent
/// of which screen is open. Two active jobs share a single audio worker.
class ImportQueue extends ChangeNotifier {
  ImportQueue(
    this._songsRoot,
    this._acceleration, {
    Future<ImportTask> Function(ImportRequest)? startAudio,
  }) : _startAudioOverride = startAudio;

  static const maxConcurrent = 2;

  final String _songsRoot;
  final VocalAcceleration _acceleration;
  final Future<ImportTask> Function(ImportRequest)? _startAudioOverride;
  final _entries = <ImportQueueEntry>[];
  final _waiting = <ImportQueueEntry>[];
  final _running = <ImportQueueEntry>{};
  final _awake = ScreenAwake();
  Future<ImportWorker>? _worker;
  Future<void> _workerClosing = Future.value();
  Future<void> _preparing = Future.value();
  int _completedCount = 0;

  Iterable<ImportQueueEntry> get entries => _entries.reversed;
  int get activeCount => _waiting.length + _running.length;
  int get completedCount => _completedCount;
  bool get usesDownloadedModels =>
      _running.any((entry) => entry._usesDownloadedModels) ||
      _waiting.any((entry) => entry._usesDownloadedModels);

  void enqueue(ImportRequest request) =>
      _enqueue(ImportQueueEntry._audio(request));

  void enqueuePackage(
    String path, {
    required String title,
    bool background = true,
  }) => _enqueue(ImportQueueEntry._package(title, path, background));

  void _enqueue(ImportQueueEntry entry) {
    _entries.add(entry);
    _waiting.add(entry);
    _advance();
  }

  Future<void> cancel(ImportQueueEntry entry) async {
    if (_waiting.remove(entry)) {
      _finish(entry, ImportQueueStatus.cancelled);
    } else if (_running.contains(entry) && entry.canCancel) {
      entry._status = ImportQueueStatus.cancelling;
      notifyListeners();
      await entry._cancelJob?.call();
    }
  }

  void _advance() {
    while (_waiting.isNotEmpty && _running.length < maxConcurrent) {
      final entry = _waiting.removeAt(0);
      final anotherImportRunning = _running.any(
        (entry) => entry._request?.mdxModelPath != null,
      );
      _running.add(entry);
      entry._status = ImportQueueStatus.running;
      entry._startedAt = DateTime.now();
      unawaited(_run(entry, anotherImportRunning));
    }
    _awake.held = _running.isNotEmpty;
    if (!_running.any((entry) => entry._request != null)) _releaseWorker();
    notifyListeners();
  }

  Future<void> _run(ImportQueueEntry entry, bool anotherImportRunning) async {
    try {
      if (entry._package case final package?) {
        final song = await (package.background
            ? importSongPackageInBackground(_songsRoot, package.path)
            : Future.sync(
                () => importSongPackageSync(_songsRoot, package.path),
              ));
        _finish(entry, ImportQueueStatus.completed, song: song);
        return;
      }

      var request = entry._request!;
      if (!request.vocalsOnly && request.mdxModelPath != null) {
        final modelPath = request.mdxModelPath!;
        final preparation = _preparing.then(
          (_) => _prepareAcceleration(modelPath, anotherImportRunning),
        );
        _preparing = preparation.then<void>(
          (_) {},
          onError: (Object _, StackTrace _) {},
        );
        final acceleration = await preparation;
        request = request.withAcceleration(
          coreML: acceleration.coreML,
          marker: acceleration.marker,
          verify: acceleration.verify,
          speed: acceleration.speed,
        );
      }
      if (entry.status == ImportQueueStatus.cancelling) {
        _finish(entry, ImportQueueStatus.cancelled);
        return;
      }

      final task = await (_startAudioOverride ?? _startAudio)(request);
      entry._cancelJob = task.cancel;
      if (entry.status == ImportQueueStatus.cancelling) {
        unawaited(task.cancel());
      }
      await for (final event in task.events) {
        switch (event) {
          case ImportProgressEvent(:final progress):
            entry._progress = progress;
            notifyListeners();
          case ImportDoneEvent(:final song):
            // Timing and acceleration settings are advisory. The song is
            // already safely in the library when the worker reports success.
            if (song.separated) unawaited(_recordAcceleration(song));
            _finish(entry, ImportQueueStatus.completed, song: song);
            return;
          case ImportFailedEvent(:final message, :final cancelled):
            _finish(
              entry,
              cancelled
                  ? ImportQueueStatus.cancelled
                  : ImportQueueStatus.failed,
              error: message,
            );
            return;
        }
      }
      throw StateError('导入进程提前结束');
    } catch (error) {
      _finish(
        entry,
        ImportQueueStatus.failed,
        error: error is SongPackageException ? error.message : '$error',
      );
    }
  }

  Future<ImportAcceleration> _prepareAcceleration(
    String path,
    bool anotherImportRunning,
  ) async {
    // A worker shutting down normally can still be removing its trial marker.
    await _workerClosing;
    final pending = _worker;
    if (anotherImportRunning && pending != null) {
      try {
        anotherImportRunning = !(await pending).isClosed;
      } catch (_) {
        anotherImportRunning = false;
      }
    }
    return _acceleration.beforeImport(
      path,
      anotherImportRunning: anotherImportRunning,
    );
  }

  Future<void> _recordAcceleration(SongMeta song) async {
    try {
      await _acceleration.afterImport(song.modelInfo);
    } catch (_) {}
  }

  Future<ImportTask> _startAudio(ImportRequest request) async {
    final pending = _worker ??= _workerClosing.then(
      (_) => ImportWorker.start(_songsRoot),
    );
    final ImportWorker worker;
    try {
      worker = await pending;
    } catch (_) {
      if (identical(_worker, pending)) _worker = null;
      rethrow;
    }
    if (worker.isClosed) {
      if (identical(_worker, pending)) _worker = null;
      return _startAudio(request);
    }
    final job = worker.startJob(request);
    return (events: job.events, cancel: job.cancel);
  }

  void _releaseWorker() {
    final pending = _worker;
    if (pending == null) return;
    _worker = null;
    _workerClosing = _closeWorker(pending);
  }

  Future<void> _closeWorker(Future<ImportWorker> pending) async {
    try {
      final worker = await pending;
      await worker.close();
    } catch (_) {}
  }

  void _finish(
    ImportQueueEntry entry,
    ImportQueueStatus status, {
    SongMeta? song,
    String? error,
  }) {
    _running.remove(entry);
    entry._status = status;
    entry._song = song;
    entry._error = error;
    entry._finishedAt = DateTime.now();
    entry._cancelJob = null;
    if (status == ImportQueueStatus.completed) _completedCount++;
    for (final path in entry._inputPaths) {
      if (!_running.any((entry) => entry._inputPaths.contains(path)) &&
          !_waiting.any((entry) => entry._inputPaths.contains(path))) {
        unawaited(discardPickedCopy(path));
      }
    }
    entry._request = null;
    entry._package = null;
    _advance();
  }
}
