// A song as one file for someone else (lib/src/library/song_package.dart):
// what goes into it, what stays with the sender, and what the receiver
// makes of a file that is not what it should be.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/export/recordings.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_package.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/practice/take_recorder.dart';

import 'support/synth_voice.dart';

const sr = 44100;
const lyrics = '[00:01.00]夜里的风慢慢吹过窗台\n[00:06.50]下雨了 记得带伞\n';

List<Syl> melody() {
  final out = <Syl>[];
  var t = 1.15;
  for (final midi in <double>[62, 64, 65, 67, 65, 64, 62, 60, 62, 64]) {
    out.add(Syl(t, t + 0.3, midi));
    t += 0.38;
  }
  t = 6.6;
  for (final midi in <double>[67, 69, 67, 72, 71, 69, 67]) {
    out.add(Syl(t, t + 0.3, midi));
    t += 0.38;
  }
  return out;
}

/// A package put together by hand, as the format is documented.
Uint8List package(Map<String, dynamic> song, List<(String role, String name, List<int> data)> files, {int version = 1}) {
  final manifest = utf8.encode(
    jsonEncode({
      'format': 'yintrace-song-package',
      'version': version,
      'song': song,
      'files': [
        for (final (role, name, data) in files)
          {'role': role, 'name': name, 'bytes': data.length, 'sha256': sha256.convert(data).toString()},
      ],
    }),
  );
  final head = ByteData(20)
    ..setUint32(12, version, Endian.little)
    ..setUint32(16, manifest.length, Endian.little);
  head.buffer.asUint8List().setRange(0, 12, ascii.encode('YinTraceSong'));
  return (BytesBuilder()
        ..add(head.buffer.asUint8List())
        ..add(manifest)
        ..add([for (final (_, _, data) in files) ...data]))
      .toBytes();
}

/// The manifest of the package at [path], and the offset of its first file.
(Map<String, dynamic>, int) manifestOf(String path) {
  final bytes = File(path).readAsBytesSync();
  expect(ascii.decode(bytes.sublist(0, 12)), 'YinTraceSong');
  final n = ByteData.sublistView(bytes).getUint32(16, Endian.little);
  return (jsonDecode(utf8.decode(bytes.sublist(20, 20 + n))) as Map<String, dynamic>, 20 + n);
}

void main() {
  late Directory tmp;
  late SongRepository mine, theirs;
  late SongMeta song;
  late String file;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('yt_package');
    mine = SongRepository(Directory('${tmp.path}/mine'));
    theirs = SongRepository(Directory('${tmp.path}/theirs'))..root.createSync();
    file = '${tmp.path}/out/song.yintrace';
    Directory('${tmp.path}/out').createSync();
    final voice = synthVoice(melody(), 10);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    writeWavFile('${tmp.path}/acc.wav', Float32List(voice.length * 2)..fillRange(0, 1000, 0.25), 2, sr);
    song = await ImportPipeline(
      audio: const WavAudioBackend(),
      repository: mine,
      loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
    ).run(
      ImportRequest(
        audioPath: '${tmp.path}/vocal.wav',
        accompanimentPath: '${tmp.path}/acc.wav',
        lyrics: lyrics,
        title: '夜航',
        artist: '演示',
        vocalsOnly: true,
      ),
    );
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  List<String> folders(SongRepository repo) => [for (final e in repo.root.listSync()) e.path.split('/').last];

  test('the receiver gets the song with its corrections, and nothing of the sender\'s practice', () async {
    // The sender corrected the melody, changed the lyrics, practised and
    // kept a recording.
    await realignSong(mine, song.id, '$lyrics[00:09.60]多加的一句\n');
    final ref = await mine.loadReference(song.id);
    ref.lines[0].tokens[2].transpose(-12);
    ref.lines[0].tokens[4].skip = true;
    await mine.saveReference(song.id, ref);
    await mine.addPractice(song.id, PracticeRecord(at: DateTime(2026, 11, 1), score: 91, lineScores: {0: 93, 1: 89}));
    final take = TakeRecorder(sampleRate: sr, lengthFrames: 10 * sr)..addAudio(Float32List(2 * sr), sr, 0);
    await keepTake(mine, song.id, take, score: 91, audio: const WavAudioBackend(), background: false);
    // How fast the sender's phone separates is nobody else's business.
    // Nor is the copy of the imported file that early versions kept: with
    // an accompaniment, nothing plays it.
    File(mine.pathFor(song.id, 'original.wav')).writeAsBytesSync(List.filled(5000, 7));
    final stored = (await mine.load(song.id)).toJson()
      ..['originalFile'] = 'original.wav'
      ..['modelInfo'] = {'mdx': 'UVR-MDX-NET-Voc_FT', 'mdxRuntime': 'Core ML', 'mdxRunSeconds': '0.412'};
    await mine.save(SongMeta.fromJson(stored));
    final sent = await mine.load(song.id);
    expect(sent.bestScore, 91);
    expect(await mine.loadRecordings(song.id), hasLength(1));

    exportSongPackageSync(mine.root.path, song.id, file);

    // One file: the header, the manifest and the four files of the song.
    final (manifest, dataStart) = manifestOf(file);
    final files = (manifest['files'] as List).cast<Map<String, dynamic>>();
    expect(files.map((f) => f['role']), ['reference', 'pitch', 'vocals', 'accompaniment']);
    expect(File(file).lengthSync(), dataStart + files.fold<int>(0, (s, f) => s + (f['bytes'] as int)));
    expect((manifest['song'] as Map).keys.toSet(), {'title', 'artist', 'duration', 'lyrics', 'separated', 'modelInfo'});
    expect(manifest['song']['modelInfo'], {'mdx': 'UVR-MDX-NET-Voc_FT'});
    final text = latin1.decode(File(file).readAsBytesSync());
    for (final private in ['bestScore', 'lastScore', 'practiceCount', 'lastPracticedAt', 'take-', sent.id]) {
      expect(text, isNot(contains(private)), reason: private);
    }
    expect(File('$file.tmp').existsSync(), isFalse);

    final got = importSongPackageSync(theirs.root.path, file);
    expect(got.id, isNot(sent.id));
    expect(folders(theirs), [got.id]);
    final listed = (await theirs.list()).single;
    expect(listed.title, '夜航');
    expect(listed.artist, '演示');
    expect(listed.duration, sent.duration);
    expect(listed.lyrics, sent.lyrics);
    expect(listed.separated, sent.separated);
    expect(listed.modelInfo, {'mdx': 'UVR-MDX-NET-Voc_FT'});
    expect(listed.createdAt.isAfter(sent.createdAt), isTrue);
    // A song that was never practised.
    expect(listed.bestScore, isNull);
    expect(listed.lastScore, isNull);
    expect(listed.practiceCount, 0);
    expect(listed.lastPracticedAt, isNull);
    expect(await theirs.loadHistory(got.id), isEmpty);
    expect(await theirs.loadRecordings(got.id), isEmpty);
    expect(
      theirs.dirFor(got.id).listSync().map((e) => e.path.split('/').last).toSet(),
      {'song.json', 'reference.json', 'pitch.bin', listed.vocalsFile, listed.accompanimentFile},
    );
    // The melody as the sender corrected it, and the same audio.
    for (final name in ['reference.json', 'pitch.bin', sent.vocalsFile, sent.accompanimentFile!]) {
      expect(
        File(theirs.pathFor(got.id, name)).readAsBytesSync(),
        File(mine.pathFor(sent.id, name)).readAsBytesSync(),
        reason: name,
      );
    }
    final theirRef = await theirs.loadReference(got.id);
    expect(theirRef.lines, hasLength(3));
    expect(theirRef.lines[0].tokens[2].shift, -12);
    expect(theirRef.lines[0].tokens[4].skip, isTrue);
    expect((await theirs.loadPitchTrack(got.id)).length, greaterThan(0));
    // The sender's song is as it was.
    expect((await mine.load(sent.id)).bestScore, 91);
    expect(await mine.loadRecordings(sent.id), hasLength(1));

    // Imported twice, it is there twice; exported again, the file is replaced.
    final again = importSongPackageSync(theirs.root.path, file);
    expect(again.id, isNot(got.id));
    expect(await theirs.list(), hasLength(2));
    final before = File(file).lengthSync();
    await realignSong(mine, song.id, lyrics);
    exportSongPackageSync(mine.root.path, song.id, file);
    expect(File(file).lengthSync(), lessThan(before));
    expect(Directory('${tmp.path}/out').listSync(), hasLength(1));
  });

  test('a song without accompaniment travels without one', () async {
    final meta = await ImportPipeline(
      audio: const WavAudioBackend(),
      repository: mine,
      loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
    ).run(ImportRequest(audioPath: '${tmp.path}/vocal.wav', lyrics: lyrics, title: ' ', vocalsOnly: true));
    exportSongPackageSync(mine.root.path, meta.id, file);
    final got = importSongPackageSync(theirs.root.path, file);
    expect(got.accompanimentFile, isNull);
    expect(got.originalFile, isNull);
    expect(got.title, meta.title);
    expect(File(theirs.pathFor(got.id, got.vocalsFile)).existsSync(), isTrue);
    // A song from an early version plays the imported file instead: that
    // one goes along.
    File(mine.pathFor(meta.id, 'original.MP3')).writeAsBytesSync(List.filled(5000, 7));
    await mine.save(SongMeta.fromJson(meta.toJson()..['originalFile'] = 'original.MP3'));
    exportSongPackageSync(mine.root.path, meta.id, file);
    final old = importSongPackageSync(theirs.root.path, file);
    expect(old.originalFile, 'original.mp3');
    expect(File(theirs.pathFor(old.id, 'original.mp3')).readAsBytesSync(), List.filled(5000, 7));
  });

  test('the file is named after the song', () {
    SongMeta named(String title, String artist) => SongMeta(
      id: 'x',
      title: title,
      artist: artist,
      createdAt: DateTime(2026),
      duration: 1,
      lyrics: '',
      vocalsFile: 'vocals.m4a',
    );
    expect(songPackageName(named('夜航', '演示')), '夜航 - 演示.yintrace');
    expect(songPackageName(named('夜航', '')), '夜航.yintrace');
    expect(songPackageName(named('a/b: c?', 'x|y')), 'a b  c - x y.yintrace');
    expect(songPackageName(named(' ', '')), '未命名.yintrace');
  });

  group('a file that is not what it should be', () {
    late Uint8List good;

    setUp(() {
      exportSongPackageSync(mine.root.path, song.id, file);
      good = File(file).readAsBytesSync();
    });

    void refused(List<int> bytes, String message) {
      final path = '${tmp.path}/received';
      File(path).writeAsBytesSync(bytes);
      expect(
        () => importSongPackageSync(theirs.root.path, path),
        throwsA(isA<SongPackageException>().having((e) => e.message, 'message', contains(message))),
      );
      expect(folders(theirs), isEmpty, reason: 'nothing of it stays in the library');
    }

    test('some other file', () {
      refused(File('${tmp.path}/vocal.wav').readAsBytesSync(), '不是音迹导出的歌曲文件');
      refused([], '不是音迹导出的歌曲文件');
      refused(utf8.encode('YinTraceSong'), '不是音迹导出的歌曲文件');
    });

    test('cut off on the way', () {
      refused(good.sublist(0, good.length - 1), '不完整');
      refused(good.sublist(0, good.length ~/ 2), '不完整');
      refused(good.sublist(0, 30), '不完整');
      refused([...good, 0], '不完整');
    });

    test('damaged on the way', () {
      refused(Uint8List.fromList(good)..[good.length - 5] ^= 1, '损坏');
      final (_, dataStart) = manifestOf(file);
      refused(Uint8List.fromList(good)..[dataStart + 3] ^= 1, '损坏');
      // The manifest itself.
      refused(Uint8List.fromList(good)..[21] = 0x7d, '读不出来');
    });

    test('from a newer version of the app', () {
      refused(Uint8List.fromList(good)..[12] = 2, '更新版本的音迹');
    });

    test('files the song page could not read', () {
      final (manifest, dataStart) = manifestOf(file);
      final song = (manifest['song'] as Map).cast<String, dynamic>();
      final parts = <String, Uint8List>{};
      var at = dataStart;
      for (final f in (manifest['files'] as List).cast<Map<String, dynamic>>()) {
        parts[f['role'] as String] = good.sublist(at, at += f['bytes'] as int);
      }
      List<(String, String, List<int>)> files({List<int>? reference, List<int>? pitch, bool vocals = true}) => [
        ('reference', 'reference.json', reference ?? parts['reference']!),
        ('pitch', 'pitch.bin', pitch ?? parts['pitch']!),
        if (vocals) ('vocals', 'vocals.wav', parts['vocals']!),
      ];
      // The hand-made package is a good one...
      File('${tmp.path}/ok').writeAsBytesSync(package(song, files()));
      final ok = importSongPackageSync(theirs.root.path, '${tmp.path}/ok');
      expect(ok.accompanimentFile, isNull);
      theirs.dirFor(ok.id).deleteSync(recursive: true);
      // ...until something in it is not.
      refused(package(song, files(reference: utf8.encode('{"lines": 3}'))), '读不出来');
      refused(package(song, files(pitch: [1, 2, 3, 4, 5, 6, 7, 8])), '读不出来');
      refused(package(song, files(vocals: false)), '读不出来');
      refused(package({...song, 'duration': 0}, files()), '读不出来');
      refused(package(song, [...files(), ('vocals', 'vocals.wav', parts['vocals']!)]), '读不出来');
    });
  });

  test('names in the file do not decide where anything is written', () {
    exportSongPackageSync(mine.root.path, song.id, file);
    final good = File(file).readAsBytesSync();
    final (manifest, dataStart) = manifestOf(file);
    final entries = (manifest['files'] as List).cast<Map<String, dynamic>>();
    final parts = <String, Uint8List>{};
    var at = dataStart;
    for (final f in entries) {
      parts[f['role'] as String] = good.sublist(at, at += f['bytes'] as int);
    }
    File('${tmp.path}/crafted').writeAsBytesSync(
      package((manifest['song'] as Map).cast<String, dynamic>(), [
        ('reference', '../../escaped.json', parts['reference']!),
        ('pitch', '/etc/pitch.bin', parts['pitch']!),
        ('vocals', '../../../escaped.WAV', parts['vocals']!),
        ('accompaniment', 'acc.wav/../../x', parts['accompaniment']!),
        // From a version that knows more: skipped.
        ('cover', 'cover.jpg', [1, 2, 3]),
      ]),
    );
    final before = tmp.listSync(recursive: true).map((e) => e.path).toSet();
    final got = importSongPackageSync(theirs.root.path, '${tmp.path}/crafted');
    expect(got.vocalsFile, 'vocals.wav');
    expect(got.accompanimentFile, 'accompaniment');
    final added = tmp.listSync(recursive: true).map((e) => e.path).toSet().difference(before);
    expect(added, {
      theirs.dirFor(got.id).path,
      for (final name in ['song.json', 'reference.json', 'pitch.bin', 'vocals.wav', 'accompaniment'])
        theirs.pathFor(got.id, name),
    });
  });

  test('a song whose files are not all there is not exported', () {
    File(mine.pathFor(song.id, song.accompanimentFile!)).deleteSync();
    expect(
      () => exportSongPackageSync(mine.root.path, song.id, file),
      throwsA(isA<SongPackageException>().having((e) => e.message, 'message', contains('文件不全'))),
    );
    expect(Directory('${tmp.path}/out').listSync(), isEmpty);
  });

  test('in the background, like the app does it', () async {
    await exportSongPackageInBackground(mine.root.path, song.id, file);
    final got = await importSongPackageInBackground(theirs.root.path, file);
    expect((await theirs.list()).single.id, got.id);
    File('${tmp.path}/bad').writeAsStringSync('not a song');
    await expectLater(
      importSongPackageInBackground(theirs.root.path, '${tmp.path}/bad'),
      throwsA(isA<SongPackageException>()),
    );
  });
}
