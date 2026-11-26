import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/dsp/reverb.dart';
import 'package:yintrace/src/export/export_files.dart';
import 'package:yintrace/src/export/mixdown.dart';
import 'package:yintrace/src/export/recordings.dart';
import 'package:yintrace/src/library/recording.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/practice/take_recorder.dart';

const sr = 44100;

double rms(Float32List x, [int from = 0, int? to, int step = 1, int offset = 0]) {
  var s = 0.0, n = 0;
  for (var i = from * step + offset; i < (to ?? x.length ~/ step) * step; i += step) {
    s += x[i] * x[i];
    n++;
  }
  return n == 0 ? 0 : math.sqrt(s / n);
}

Float32List tone(double seconds, double hz, double amp) =>
    Float32List.fromList([for (var i = 0; i < (seconds * sr).round(); i++) amp * math.sin(2 * math.pi * hz * i / sr)]);

void main() {
  test('the start on Android clears exports left behind, and those 1.0.0 kept out of reach', () async {
    final tmp = Directory.systemTemp.createTempSync('yt_sweep');
    addTearDown(() => tmp.deleteSync(recursive: true));
    File make(String path) => File('${tmp.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync('x');
    final exports = Directory('${tmp.path}/cache/exports');
    final documents = Directory('${tmp.path}/app_flutter');
    final left = [
      make('cache/exports/夜航 - 我的演唱 2026-11-20 2130.wav'),
      make('cache/exports/夜航 - 演示.yintrace.tmp'),
      make('app_flutter/夜航 - 我的演唱 2026-11-20 2130.wav'),
      make('app_flutter/夜航 - 我的演唱 2026-11-20 2130 (2).m4a'),
      make('app_flutter/夜航 - 演示.yintrace'),
      make('app_flutter/夜航 - 演示.yintrace.tmp'),
    ];
    final kept = [
      make('app_flutter/flutter_assets/sounds/click.wav'), // the engine's
      make('app_flutter/res_timestamp-1-1764000000000'),
      make('cache/key-shifts/song/+2.wav'),
    ];
    await sweepExports(exports: exports, documents: documents);
    for (final f in left) {
      expect(f.existsSync(), isFalse, reason: f.path);
    }
    for (final f in kept) {
      expect(f.existsSync(), isTrue, reason: f.path);
    }
    expect(exports.existsSync(), isTrue);
    // Nothing there yet: no error.
    await sweepExports(exports: Directory('${tmp.path}/none'), documents: Directory('${tmp.path}/none'));
  });

  test('reverb rings out and is wider than the voice', () {
    final impulse = Float32List(sr)..[0] = 1;
    final l = Float32List(sr * 3), r = Float32List(sr * 3);
    Reverb().process(impulse, l, r, tail: sr * 2);
    expect(l.every((v) => v.isFinite) && r.every((v) => v.isFinite), isTrue);
    final early = rms(l, 0, sr ~/ 4), late = rms(l, (2.5 * sr).round(), 3 * sr);
    expect(early, greaterThan(0));
    expect(late, lessThan(early * 0.01), reason: 'decays by more than 40 dB within 2.5 s');
    var same = true;
    for (var i = 2000; i < 3000; i++) {
      if ((l[i] - r[i]).abs() > 1e-6) same = false;
    }
    expect(same, isFalse, reason: 'left and right differ');
  });

  test('mix places the voice where it was sung, with its gains and the alignment', () {
    final acc = Float32List(10 * sr * 2);
    for (var i = 0; i < 10 * sr; i++) {
      acc[2 * i] = 0.1;
      acc[2 * i + 1] = -0.1;
    }
    final voice = Float32List(sr)..fillRange(0, sr, 0.2); // 1 s at song time 4 s
    final settings = MixSettings(vocal: 1, accompaniment: 0.5, reverb: 0, wholeSong: true);
    final mix = renderMix(
      voice: voice,
      voiceStart: 4,
      accompaniment: acc,
      settings: settings,
      from: 0,
      to: 10,
      songDuration: 10,
    );
    expect(mix.length, 10 * sr * 2);
    expect(mix[2 * (2 * sr)], closeTo(0.05, 1e-6)); // accompaniment only
    expect(mix[2 * (2 * sr) + 1], closeTo(-0.05, 1e-6));
    expect(mix[2 * (4 * sr + 100)], closeTo(0.25, 1e-6)); // + the voice
    expect(mix[2 * (5 * sr + 100)], closeTo(0.05, 1e-6));
    // 100 ms later.
    settings.offsetMs = 100;
    final later = renderMix(
      voice: voice,
      voiceStart: 4,
      accompaniment: acc,
      settings: settings,
      from: 0,
      to: 10,
      songDuration: 10,
    );
    expect(later[2 * (4 * sr + 100)], closeTo(0.05, 1e-6));
    expect(later[2 * (4 * sr + 4500)], closeTo(0.25, 1e-6));
    // Only the voice.
    settings
      ..offsetMs = 0
      ..vocalOnly = true;
    final dry = renderMix(
      voice: voice,
      voiceStart: 4,
      accompaniment: acc,
      settings: settings,
      from: 3,
      to: 8,
      songDuration: 10,
    );
    expect(dry[2 * (sr ~/ 2)], 0);
    expect(dry[2 * (sr + 100)], closeTo(0.2, 1e-6));
  });

  test('mix fades where it cuts into the song and never clips', () {
    final acc = Float32List(20 * sr * 2)..fillRange(0, 20 * sr * 2, 0.6);
    final voice = tone(4, 440, 0.8);
    final s = MixSettings(vocal: 1.5, accompaniment: 1.5, reverb: 0.5, wholeSong: false);
    final (from, to) = mixRange(takeStart: 8, takeEnd: 12, songDuration: 20, wholeSong: false);
    expect(from, 6);
    expect(to, 15);
    final mix = renderMix(
      voice: voice,
      voiceStart: 8,
      accompaniment: acc,
      settings: s,
      from: from,
      to: to,
      songDuration: 20,
    );
    final peak = mix.fold<double>(0, (m, v) => math.max(m, v.abs()));
    expect(peak, lessThanOrEqualTo(0.97 + 1e-6));
    expect(mix[0].abs(), lessThan(0.01), reason: 'fades in');
    expect(mix[mix.length - 2].abs(), lessThan(0.01), reason: 'fades out');
    expect(mixRange(takeStart: 8, takeEnd: 12, songDuration: 20, wholeSong: true), (0.0, 20.0));
  });

  test('settings and recordings round-trip', () {
    final r = Recording(
      id: 'take-1',
      createdAt: DateTime(2026, 11, 14, 18, 20),
      file: 'take-1.m4a',
      start: 12.5,
      duration: 61,
      score: 83.4,
      mix: MixSettings(vocal: 1.2, accompaniment: 0.7, reverb: 0.4, offsetMs: -40, wholeSong: false, vocalOnly: true),
    );
    final copy = Recording.fromJson(r.toJson());
    expect(copy.start, 12.5);
    expect(copy.end, 73.5);
    expect(copy.score, 83.4);
    expect(copy.mix.toJson(), r.mix.toJson());
    expect(MixSettings.fromJson(const {}).toJson(), MixSettings().toJson());
  });

  test('export file names are safe', () {
    expect(exportName('夜航/示例: 1', DateTime(2026, 11, 4, 9, 5)), '夜航 示例  1 - 我的演唱 2026-11-04 0905');
    expect(exportName('  ', DateTime(2026, 1, 1)), '未命名 - 我的演唱 2026-01-01 0000');
  });

  group('kept takes', () {
    late Directory tmp;
    late SongRepository repo;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('yt_takes');
      repo = SongRepository(Directory('${tmp.path}/songs'));
      repo.dirFor('song').createSync(recursive: true);
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a take is kept as the sung part, listed and deleted', () async {
      final take = TakeRecorder(sampleRate: sr, lengthFrames: 10 * sr);
      take.addAudio(tone(2, 330, 0.3), 3 * sr, 0); // sung 3..5 s
      final r = await keepTake(repo, 'song', take, score: 77, audio: const WavAudioBackend(), background: false);
      expect(r.start, closeTo(2.8, 1e-3));
      expect(r.duration, closeTo(2.4, 1e-3));
      expect(r.file, endsWith('.wav'));
      expect(r.mix.wholeSong, isFalse, reason: '2 s of a 10 s song');
      final audio = readWavFile(repo.recordingPath('song', r));
      expect(audio.frames, (2.4 * sr).round());
      expect(audio.samples[(0.2 * sr).round() + 1000], closeTo(take.samples![3 * sr + 1000], 1e-3));
      final listed = await repo.loadRecordings('song');
      expect(listed.single.id, r.id);
      expect(listed.single.score, 77);
      await repo.deleteRecording('song', r);
      expect(await repo.loadRecordings('song'), isEmpty);
    });

    test('export writes the mix of a kept take', () async {
      final acc = Float32List(8 * sr * 2);
      for (var i = 0; i < 8 * sr; i++) {
        acc[2 * i] = acc[2 * i + 1] = 0.05 * math.sin(2 * math.pi * 110 * i / sr);
      }
      writeWavFile('${tmp.path}/acc.wav', acc, 2, sr);
      final voicePath = '${tmp.path}/voice.wav';
      writeWavFile(voicePath, tone(2, 440, 0.3), 1, sr);
      final job = ExportJob(
        voicePath: voicePath,
        voiceStart: 3,
        accompanimentPath: '${tmp.path}/acc.wav',
        songDuration: 8,
        settings: MixSettings(reverb: 0.3),
        outputBase: '${tmp.path}/out',
      );
      final progress = <double>[];
      final path = exportNow(job.toMessage(), onProgress: progress.add);
      expect(File(path).existsSync(), isTrue);
      expect(progress.last, 1);
      final out = const WavAudioBackend().decode(path);
      expect(out.frames, 8 * sr);
      // Only the voice, over the whole song: as long as the song, so it lines
      // up with it elsewhere; only the sung part: the voice and its reverb.
      final stem = exportNow(
        ExportJob(
          voicePath: voicePath,
          voiceStart: 3,
          accompanimentPath: '${tmp.path}/acc.wav',
          songDuration: 8,
          settings: MixSettings(vocalOnly: true),
          outputBase: '${tmp.path}/stem',
        ).toMessage(),
      );
      expect(const WavAudioBackend().decode(stem).frames, 8 * sr);
      final part = exportNow(
        ExportJob(
          voicePath: voicePath,
          voiceStart: 3,
          accompanimentPath: '${tmp.path}/acc.wav',
          songDuration: 8,
          settings: MixSettings(vocalOnly: true, wholeSong: false),
          outputBase: '${tmp.path}/part',
        ).toMessage(),
      );
      expect(
        const WavAudioBackend().decode(part).frames,
        ((2 + 2 + reverbTail) * sr).round(),
        reason: '2 s before the voice, the voice, its reverb tail',
      );
      final before = rms(out.samples, sr, 2 * sr, 2), during = rms(out.samples, 3 * sr + 2000, 4 * sr, 2);
      expect(during, greaterThan(before * 3), reason: 'the voice is in from 3 s');
    }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null ? 'needs the native core (AAC encoder probe)' : null);
  });
}
