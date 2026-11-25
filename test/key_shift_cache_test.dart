import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/audio/key_shift_cache.dart';

bool _current() => true;

List<int>? _read(KeyShiftCacheEntry entry) => entry.read((file) => file.readAsBytesSync(), isCurrent: _current);

bool _store(KeyShiftCacheEntry entry, int value, {int size = 16}) {
  var wrote = false;
  entry.store(size, (file) {
    wrote = true;
    file.writeAsBytesSync(List.filled(size, value));
  }, isCurrent: _current);
  return wrote;
}

Future<bool> _storeInWorker(KeyShiftCacheEntry entry, int value, {SendPort? starting}) => Isolate.run(() {
  starting?.send(null);
  return _store(entry, value);
});

Future<List<int>?> _holdRead(KeyShiftCacheEntry entry, SendPort entered, String releasePath) => Isolate.run(
  () => entry.read((file) {
    entered.send(null);
    final release = File(releasePath);
    final timer = Stopwatch()..start();
    while (!release.existsSync()) {
      if (timer.elapsed > const Duration(seconds: 10)) {
        throw StateError('timed out waiting to release cache reader');
      }
      sleep(const Duration(milliseconds: 5));
    }
    return file.readAsBytesSync();
  }, isCurrent: _current),
);

void main() {
  late Directory tmp;
  late Directory root;
  late KeyShiftCache a;
  late KeyShiftCache b;

  setUp(() {
    tmp = Directory.systemTemp.createTempSync('yt_key_shift_cache');
    root = Directory('${tmp.path}/key-shifts');
    a = KeyShiftCache(root.path, 'a', maxBytes: 32);
    b = KeyShiftCache(root.path, 'b', maxBytes: 32);
    a.directory.createSync(recursive: true);
    b.directory.createSync();
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  test('global cap evicts least recently read WAVs across songs and includes v1 entries', () async {
    final first = a.entry('acc.wav', 'hash', 44100, 2);
    final second = b.entry('vocals.wav', 'hash', 48000, 2);
    final third = b.entry('vocals.wav', 'hash', 48000, 3);
    expect(_store(first, 1), isTrue);
    expect(_store(second, 2), isTrue);
    final firstFile = a.directory.listSync().whereType<File>().single;
    final secondFile = b.directory.listSync().whereType<File>().single;
    firstFile.setLastModifiedSync(DateTime(2000));
    secondFile.setLastModifiedSync(DateTime(2001));
    expect(_read(first), List.filled(16, 1)); // Used again after the second entry.
    expect(_store(third, 3), isTrue);
    expect(secondFile.existsSync(), isFalse);
    expect(firstFile.existsSync(), isTrue);
    expect(_read(third), List.filled(16, 3));

    // An upgrade may already have more than the budget in the directory.
    final legacy = File('${b.directory.path}/v1-44100-2-${'a' * 64}.wav')
      ..writeAsBytesSync(List.filled(16, 4))
      ..setLastModifiedSync(DateTime(1999));
    final abandoned = a.directory.createTempSync('write-');
    File('${abandoned.path}/audio.wav').writeAsBytesSync([1, 2, 3]);
    final unknown = File('${a.directory.path}/other.wav')..writeAsBytesSync([5]);
    final original = File('${tmp.path}/acc.wav')..writeAsBytesSync([6]);
    await KeyShiftCache.trimInBackground(root.path, maxBytes: 32);
    expect(legacy.existsSync(), isFalse);
    expect(abandoned.existsSync(), isFalse);
    expect(firstFile.existsSync(), isTrue);
    expect(unknown.readAsBytesSync(), [5]);
    expect(original.readAsBytesSync(), [6]);
  });

  test('a different source hash removes that stem across keys and rates', () {
    final wide = KeyShiftCache(root.path, 'a', maxBytes: 64);
    final oldKey = wide.entry('acc.wav', 'old', 44100, 2);
    final oldRate = wide.entry('acc.wav', 'old', 48000, 3);
    final vocals = wide.entry('vocals.wav', 'guide', 44100, 2);
    final latest = wide.entry('acc.wav', 'new', 44100, 2);
    _store(oldKey, 1);
    _store(oldRate, 2);
    _store(vocals, 3);
    _store(latest, 4);
    expect(_read(oldKey), isNull);
    expect(_read(oldRate), isNull);
    expect(_read(vocals), List.filled(16, 3));
    expect(_read(latest), List.filled(16, 4));
    oldKey.store(16, (_) => fail('a superseded render must not publish'), isCurrent: () => false);
    expect(_read(latest), List.filled(16, 4));
  });

  test('parallel isolates publish one copy per key and stay within the byte cap', () async {
    final first = a.entry('acc.wav', 'hash', 44100, 2);
    final second = b.entry('acc.wav', 'hash', 44100, 2);
    final third = b.entry('acc.wav', 'hash', 44100, 3);
    final wrote = await Future.wait([_storeInWorker(first, 1), _storeInWorker(first, 2), _storeInWorker(second, 3)]);
    expect(wrote.take(2).where((value) => value), hasLength(1));
    expect(wrote.last, isTrue);
    expect(_read(first), List.filled(16, wrote.first ? 1 : 2));
    expect(_read(second), List.filled(16, 3));

    await Future.wait([_storeInWorker(third, 4), _storeInWorker(a.entry('acc.wav', 'hash', 48000, 2), 5)]);
    final files = root.listSync(recursive: true).whereType<File>().where((file) => file.path.endsWith('.wav'));
    expect(files.map((file) => file.lengthSync()), [16, 16]);
    expect(root.listSync(recursive: true).whereType<Directory>(), hasLength(2));
  });

  test('an open read finishes before another worker can evict its WAV', () async {
    final small = KeyShiftCache(root.path, 'a', maxBytes: 16);
    final first = small.entry('acc.wav', 'hash', 44100, 2);
    final next = small.entry('acc.wav', 'hash', 44100, 3);
    _store(first, 1);
    final file = small.directory.listSync().whereType<File>().single;
    final release = File('${tmp.path}/release');
    final entered = ReceivePort();
    final starting = ReceivePort();
    final reader = _holdRead(first, entered.sendPort, release.path);
    try {
      await entered.first.timeout(const Duration(seconds: 5));
      var wrote = false;
      final writer = _storeInWorker(next, 2, starting: starting.sendPort).then((value) => wrote = value);
      try {
        await starting.first.timeout(const Duration(seconds: 5));
        await Future<void>.delayed(const Duration(milliseconds: 100));
        expect(wrote, isFalse);
        expect(file.existsSync(), isTrue);
      } finally {
        release.createSync();
        await writer;
      }
      expect(await reader, List.filled(16, 1));
      expect(file.existsSync(), isFalse);
      expect(_read(next), List.filled(16, 2));
    } finally {
      release.createSync();
      entered.close();
      starting.close();
      await reader;
    }
  });

  test('ENOSPC discards a partial write and a later attempt can repopulate it', () {
    final first = a.entry('acc.wav', 'hash', 44100, 2);
    first.store(16, (file) {
      file.writeAsBytesSync([1, 2, 3]);
      throw FileSystemException('write', file.path, const OSError('No space left on device', 28));
    }, isCurrent: _current);
    expect(a.directory.listSync(), isEmpty);
    expect(_read(first), isNull);
    expect(_store(first, 4), isTrue);
    expect(_read(first), List.filled(16, 4));
    final large = a.entry('acc.wav', 'hash', 44100, 3);
    expect(_store(large, 5, size: 33), isFalse);
    expect(_read(first), List.filled(16, 4));
  });
}
