import 'dart:io';

/// Replaces the file at [path] with [content] in one step: whoever reads it
/// (also the next start of the app, after a crash) finds the old content or
/// the new one, never a mix of the two. Two writes of the same file must not
/// run at the same time (they share the temporary file): see
/// [LatestStateWriter].
Future<void> writeFileAtomic(String path, String content) async {
  final tmp = File('$path.tmp');
  await tmp.writeAsString(content, flush: true);
  await tmp.rename(path);
}

/// Keeps a file up to date with a state that changes quickly (a slider being
/// dragged): one write at a time, each of the newest state. A change that
/// arrives while a write is running is written right after it; changes in
/// between are skipped, their state is already out of date.
class LatestStateWriter {
  LatestStateWriter(this.file, this.content);

  final File file;

  /// The state to store, read when a write starts.
  final String Function() content;

  Future<void>? _running;
  bool _stale = false;

  /// Completes when the state as it is now (or a newer one) is in the file.
  Future<void> save() {
    _stale = true;
    return _running ??= _run();
  }

  Future<void> _run() async {
    try {
      while (_stale) {
        _stale = false;
        await file.parent.create(recursive: true);
        await writeFileAtomic(file.path, content());
      }
    } finally {
      // In the same step as the last look at _stale: a save() after this
      // starts a new run instead of waiting for one that is over.
      _running = null;
    }
  }
}
