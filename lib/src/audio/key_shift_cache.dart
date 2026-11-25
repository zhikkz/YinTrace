import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:crypto/crypto.dart';
import 'package:ffi/ffi.dart';

/// The cache lives under one dedicated root, with a directory for each song.
/// Its files are disposable, including after a failed write or interrupted app.
class KeyShiftCache {
  const KeyShiftCache(this.rootPath, this.songId, {this.maxBytes = defaultMaxBytes});

  static const defaultMaxBytes = 512 * 1024 * 1024;
  static final _legacyName = RegExp(r'^v1-\d+--?\d+-[0-9a-f]{64}\.wav$');
  static final _entryName = RegExp(r'^v2-\d+--?\d+-([0-9a-f]{64})-([0-9a-f]{64})\.wav$');

  final String rootPath;
  final String songId;
  final int maxBytes;

  Directory get directory => Directory('$rootPath/$songId');

  KeyShiftCacheEntry entry(String sourceName, String sourceHash, int sampleRate, int transpose) {
    final stem = sha256.convert(utf8.encode(sourceName)).toString();
    final identity = sha256.convert(utf8.encode('$sourceName\n$sourceHash')).toString();
    final shift = '$sampleRate-$transpose';
    return KeyShiftCacheEntry._(
      this,
      File('${directory.path}/v2-$shift-$stem-$identity.wav'),
      File('${directory.path}/v1-$shift-$identity.wav'),
      stem,
      identity,
    );
  }

  static Future<void> trimInBackground(String rootPath, {int maxBytes = defaultMaxBytes}) => Isolate.run(() {
    _withCacheLock(rootPath, () => _makeRoom(rootPath, maxBytes));
  });

  Future<void> deleteInBackground() => Isolate.run(() {
    _withCacheLock(rootPath, () {
      final dir = directory;
      if (dir.existsSync()) dir.deleteSync(recursive: true);
    });
  });

  // Scan only generated files in the song directories. Staging takes place
  // under the same lock, so any staging directory we find was abandoned.
  static void _makeRoom(String rootPath, int maxBytes) {
    final entries = <(File, FileStat)>[];
    var bytes = 0;
    for (final song in Directory(rootPath).listSync(followLinks: false).whereType<Directory>()) {
      for (final entity in song.listSync(followLinks: false)) {
        final name = entity.uri.pathSegments.where((part) => part.isNotEmpty).last;
        if (entity is Directory && name.startsWith('write-')) {
          entity.deleteSync(recursive: true);
        } else if (entity is File && (_entryName.hasMatch(name) || _legacyName.hasMatch(name))) {
          final stat = entity.statSync();
          if (stat.type != FileSystemEntityType.file) continue;
          entries.add((entity, stat));
          bytes += stat.size;
        }
      }
    }
    if (bytes <= maxBytes) return;
    entries.sort((a, b) {
      final byTime = a.$2.modified.compareTo(b.$2.modified);
      return byTime != 0 ? byTime : a.$1.path.compareTo(b.$1.path);
    });
    for (final (file, stat) in entries) {
      file.deleteSync();
      bytes -= stat.size;
      if (bytes <= maxBytes) break;
    }
  }
}

class KeyShiftCacheEntry {
  const KeyShiftCacheEntry._(this._cache, this._file, this._legacy, this._stem, this._identity);

  final KeyShiftCache _cache;
  final File _file;
  final File _legacy;
  final String _stem;
  final String _identity;

  /// Keep the file until the caller has finished decoding it into memory.
  T? read<T>(T? Function(File) read, {required bool Function() isCurrent}) => _withCacheLock<T?>(_cache.rootPath, () {
    if (!isCurrent()) return null;
    for (final file in [_file, _legacy]) {
      if (FileSystemEntity.typeSync(file.path, followLinks: false) != FileSystemEntityType.file) {
        continue;
      }
      final audio = read(file);
      if (!isCurrent()) return null;
      if (audio == null) {
        file.deleteSync();
        continue;
      }
      try {
        if (file == _legacy) {
          _discardOldHashes();
          file.renameSync(_file.path).setLastModifiedSync(DateTime.now());
        } else {
          file.setLastModifiedSync(DateTime.now());
        }
      } on FileSystemException {
        // A valid decode can still be used if touching or migrating it fails.
      }
      return audio;
    }
    return null;
  });

  void store(int byteCount, void Function(File) write, {required bool Function() isCurrent}) {
    _withCacheLock(_cache.rootPath, () {
      final dir = _cache.directory;
      // A competing writer may have filled the entry, or the song may have
      // been deleted while the DSP was running. Do not recreate its directory.
      if (!dir.existsSync() || !isCurrent() || _file.existsSync()) return;
      _discardOldHashes();
      if (byteCount > _cache.maxBytes) return;
      KeyShiftCache._makeRoom(_cache.rootPath, _cache.maxBytes - byteCount);
      final staging = dir.createTempSync('write-');
      try {
        final file = File('${staging.path}/audio.wav');
        write(file);
        if (file.lengthSync() == byteCount && isCurrent()) {
          file.renameSync(_file.path);
        }
      } finally {
        staging.deleteSync(recursive: true);
      }
    });
  }

  void _discardOldHashes() {
    for (final file in _cache.directory.listSync(followLinks: false).whereType<File>()) {
      final match = KeyShiftCache._entryName.firstMatch(file.uri.pathSegments.last);
      if (match != null && match[1] == _stem && match[2] != _identity) {
        file.deleteSync();
      }
    }
  }
}

// POSIX dart:io locks are process-wide, so use flock's per-open-handle lock
// to coordinate the practice, preview and export isolates. On Windows,
// dart:io already locks per handle. Never unlink the lock file during a trim.
typedef _Open = Int Function(Pointer<Utf8>, Int);
typedef _Flock = Int Function(Int, Int);
typedef _Close = Int Function(Int);

final _libc = DynamicLibrary.process();
final _open = _libc.lookupFunction<_Open, int Function(Pointer<Utf8>, int)>('open');
final _flock = _libc.lookupFunction<_Flock, int Function(int, int)>('flock');
final _close = _libc.lookupFunction<_Close, int Function(int)>('close');

T? _withCacheLock<T>(String rootPath, T Function() operation) {
  try {
    if (!Directory(rootPath).existsSync()) return null;
    final lock = File('$rootPath/.lock')..createSync();
    if (Platform.isWindows) {
      final handle = lock.openSync(mode: FileMode.append);
      try {
        handle.lockSync(FileLock.blockingExclusive);
        return operation();
      } finally {
        handle.closeSync();
      }
    }
    const readOnly = 0, exclusive = 2;
    final fd = using((arena) => _open(lock.path.toNativeUtf8(allocator: arena), readOnly));
    if (fd < 0) return null;
    try {
      return _flock(fd, exclusive) == 0 ? operation() : null;
    } finally {
      _close(fd);
    }
  } on FileSystemException {
    // The system may remove the cache, or the disk may be full. Callers can
    // still decode from the source and use their in-memory audio.
    return null;
  }
}
