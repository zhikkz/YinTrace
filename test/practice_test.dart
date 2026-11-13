import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/scoring.dart';
import 'package:yintrace/src/separation/tensor_model.dart';

import 'support/synth_voice.dart';

const sr = 44100;

/// A short two line song used throughout this file.
final syls = <Syl>[
  for (var i = 0; i < 6; i++) Syl(1.1 + i * 0.4, 1.1 + i * 0.4 + 0.33, <double>[60, 62, 64, 65, 67, 67][i]),
  for (var i = 0; i < 4; i++) Syl(5.1 + i * 0.5, 5.1 + i * 0.5 + 0.42, <double>[69, 67, 65, 64][i]),
];
const lyrics = '[00:01.00]雨点落在屋檐\n[00:05.00]滴答作响\n';

/// Identity "separation": MDX returns the input spectrogram unchanged and
/// the VR mask is 0 (everything goes to the secondary = lead vocal stem).
class PassThroughModel implements TensorModel {
  PassThroughModel(this.kind);
  final String kind;
  @override
  Future<Float32List> run(Float32List input, List<int> shape) async =>
      kind == 'mdx' ? Float32List.fromList(input) : Float32List(input.length);
  @override
  Future<void> close() async {}
}

SongReference makeReference() {
  final voice = synthVoice(syls, 8);
  return buildReference(analyzePitch(voice, sr), parseLrc(lyrics).lines);
}

/// Live samples every 10 ms from [from] to [to] produced by [midiAt].
List<LivePitch> sing(double from, double to, double Function(double t) midiAt) => [
      for (var t = from; t < to; t += 0.01)
        LivePitch(songTime: t, clockTime: t, midi: midiAt(t), levelDb: -20, playing: true, aperiodicity: 0.05)
    ];

double refMidi(double t) {
  for (final s in syls) {
    if (t >= s.start && t < s.end) return s.midi;
  }
  return 0;
}

void main() {
  group('ImportPipeline', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('yt_import'));
    tearDown(() => tmp.deleteSync(recursive: true));

    test('separates, analyses, aligns and stores a song', () async {
      final voice = synthVoice(syls, 8);
      final stereo = Float32List(voice.length * 2);
      for (var i = 0; i < voice.length; i++) {
        stereo[2 * i] = voice[i];
        stereo[2 * i + 1] = voice[i];
      }
      final input = '${tmp.path}/song.wav';
      writeWavFile(input, stereo, 2, sr);
      File('${tmp.path}/mdx.onnx').writeAsStringSync('fake');
      File('${tmp.path}/vr.onnx').writeAsStringSync('fake');
      final repo = SongRepository(Directory('${tmp.path}/songs'));
      final stages = <ImportStage>{};
      var lastOverall = 0.0;
      final pipeline = ImportPipeline(
        audio: const WavAudioBackend(),
        repository: repo,
        loadModel: (path, {inputName, outputName, useCoreML = false}) async => (
          model: PassThroughModel(path.contains('mdx') ? 'mdx' : 'vr'),
          inputShape: path.contains('vr') ? [1, 2, 673, 512] : null,
        ),
      );
      final meta = await pipeline.run(
        ImportRequest(
          audioPath: input,
          lyrics: lyrics,
          title: '测试歌曲',
          artist: '某人',
          mdxModelPath: '${tmp.path}/mdx.onnx',
          vrModelPath: '${tmp.path}/vr.onnx',
        ),
        onProgress: (p) {
          stages.add(p.stage);
          expect(p.overall, greaterThanOrEqualTo(lastOverall - 1e-9));
          lastOverall = p.overall;
        },
      );
      expect(stages, containsAll(ImportStage.values));
      expect(lastOverall, closeTo(1, 1e-9));
      expect(meta.title, '测试歌曲');
      expect(meta.duration, closeTo(8, 0.01));
      expect(meta.vocalsFile, 'vocals.wav');
      expect(meta.accompanimentFile, 'accompaniment.wav');
      expect(meta.originalFile, 'original.wav');

      final songs = await repo.list();
      expect(songs.map((s) => s.id), [meta.id]);
      final ref = await repo.loadReference(meta.id);
      expect(ref.lines.length, 2);
      expect(ref.tokens.map((t) => t.text).join(), '雨点落在屋檐滴答作响');
      final tokens = ref.tokens.toList();
      for (var i = 0; i < tokens.length; i++) {
        expect(tokens[i].meanMidi, closeTo(syls[i].midi, 0.6), reason: tokens[i].text);
      }
      final track = await repo.loadPitchTrack(meta.id);
      expect(track.duration, closeTo(8, 0.05));
      // MDX pass-through + VR mask 0 => vocals ~ mix * compensate, so the
      // accompaniment (mix - vocals) is tiny compared to the mix.
      final acc = readWavFile(repo.pathFor(meta.id, meta.accompanimentFile!));
      double rms(Float32List x) => math.sqrt(x.fold<double>(0, (s, v) => s + v * v) / x.length);
      expect(rms(acc.samples) / rms(stereo), lessThan(0.08));

      // Lyrics edits re-align without re-separation.
      await realignSong(repo, meta.id, '[00:01.00]雨点落在屋檐\n');
      expect((await repo.loadReference(meta.id)).lines.length, 1);

      // Practice history.
      final updated = await repo.addPractice(
          meta.id, PracticeRecord(at: DateTime.now(), score: 87.5, lineScores: {0: 90, 1: 85}));
      expect(updated.bestScore, 87.5);
      expect(updated.practiceCount, 1);
      expect((await repo.loadHistory(meta.id)).single.lineScores[1], 85);

      await repo.delete(meta.id);
      expect(await repo.list(), isEmpty);
    });

    test('vocal-only import skips separation; bad input cleans up', () async {
      final voice = synthVoice(syls, 8);
      final input = '${tmp.path}/vocal.wav';
      writeWavFile(input, voice, 1, 48000);
      final repo = SongRepository(Directory('${tmp.path}/songs'));
      final pipeline = ImportPipeline(
        audio: const WavAudioBackend(),
        repository: repo,
        loadModel: (path, {inputName, outputName, useCoreML = false}) =>
            throw StateError('no models needed'),
      );
      final meta = await pipeline.run(
          ImportRequest(audioPath: input, lyrics: lyrics, title: 'v', vocalsOnly: true));
      expect(meta.separated, isFalse);
      expect(meta.accompanimentFile, isNull);
      expect((await repo.loadReference(meta.id)).tokens.length, 10);

      await expectLater(
          pipeline.run(ImportRequest(audioPath: input, lyrics: 'no timestamps', title: 'x', vocalsOnly: true)),
          throwsA(isA<ImportException>()));
      await expectLater(
          pipeline.run(ImportRequest(audioPath: '${tmp.path}/missing.wav', lyrics: lyrics, title: 'x', vocalsOnly: true)),
          throwsA(isA<FileSystemException>()));
      expect((await repo.list()).length, 1, reason: 'failed imports leave nothing behind');
    });
  });

  group('LivePitchTracker', () {
    test('maps capture blocks to latency-compensated song time, across a loop jump', () {
      final tracker = LivePitchTracker(
          sampleRate: sr, options: const LivePitchOptions(latencySeconds: 0.1));
      const hz = 220.0;
      var phase = 0.0;
      Float32List block(int n) {
        final b = Float32List(n);
        for (var i = 0; i < n; i++) {
          phase += hz / sr;
          b[i] = 0.3 * math.sin(2 * math.pi * phase);
        }
        return b;
      }

      final out = <LivePitch>[];
      var clock = 0;
      // 1 s of playback starting at song frame 10 s, then a jump back to 3 s.
      var song = 10 * sr;
      for (var k = 0; k < 86; k++) {
        out.addAll(tracker.addBlock(block(512), song, clock, true));
        song += 512;
        clock += 512;
      }
      final beforeJump = out.length;
      song = 3 * sr;
      for (var k = 0; k < 40; k++) {
        out.addAll(tracker.addBlock(block(512), song, clock, true));
        song += 512;
        clock += 512;
      }
      expect(out.length, greaterThan(100));
      for (final p in out.skip(2)) {
        expect(p.midi, closeTo(hzToMidi(hz), 0.1));
      }
      // First frame centre is at sample 1024 of the stream.
      expect(out.first.songTime, closeTo(10 + 1024 / sr - 0.1, 1e-6));
      expect(out[beforeJump - 1].songTime, lessThan(11.0));
      final afterJump = out.skip(beforeJump).firstWhere((p) => p.songTime < 5);
      expect(afterJump.songTime, closeTo(3, 0.1));
      // Frames are 10 ms apart.
      expect(out[11].clockTime - out[10].clockTime, closeTo(0.01, 1e-9));
    });

    test('silence and noise are unvoiced', () {
      final tracker = LivePitchTracker(sampleRate: sr);
      final rng = math.Random(1);
      final noise = Float32List.fromList(List.generate(8192, (_) => (rng.nextDouble() * 2 - 1) * 0.2));
      expect(tracker.addBlock(Float32List(8192), 0, 0, true).every((p) => !p.voiced), isTrue);
      expect(tracker.addBlock(noise, 8192, 8192, true).where((p) => p.voiced).length, lessThan(3));
    });
  });

  group('PracticeScorer', () {
    final ref = makeReference();

    test('perfect singing scores high with no issues', () {
      final s = PracticeScorer(ref);
      for (final p in sing(0.8, 7.5, refMidi)) {
        s.add(p);
      }
      final results = s.results();
      expect(results.every((r) => r.attempted), isTrue);
      expect(s.overallScore(), greaterThan(90));
      expect(results.expand((r) => r.problems), isEmpty);
    });

    test('sharp, flat, silent and octave-shifted singing', () {
      final s = PracticeScorer(ref);
      // Line 1 sung 80 cents sharp, line 2 silent.
      for (final p in sing(0.8, 4.8, (t) => refMidi(t) > 0 ? refMidi(t) + 0.8 : 0)) {
        s.add(p);
      }
      for (final p in sing(4.8, 7.5, (t) => 0)) {
        s.add(p);
      }
      final r = s.results();
      expect(r[0].tokens.every((t) => t.issues.contains(TokenIssue.sharp)), isTrue);
      expect(r[0].tokens.first.medianCents, closeTo(80, 15));
      expect(r[0].tokens.first.summary, contains('偏高'));
      expect(r[1].tokens.every((t) => t.issues.contains(TokenIssue.missed)), isTrue);
      expect(r[0].score, lessThan(70));

      final octave = PracticeScorer(ref);
      for (final p in sing(0.8, 7.5, (t) => refMidi(t) > 0 ? refMidi(t) - 12 : 0)) {
        final scored = octave.add(p);
        if (scored.deviationCents != null) expect(scored.deviationCents!.abs(), lessThan(60));
      }
      expect(octave.overallScore(), greaterThan(90));
      final strict = PracticeScorer(ref, options: const ScoringOptions(octaveTolerant: false));
      for (final p in sing(0.8, 7.5, (t) => refMidi(t) > 0 ? refMidi(t) - 12 : 0)) {
        strict.add(p);
      }
      expect(strict.overallScore(), lessThan(40));
    });

    test('late entries are reported and loops start a new pass', () {
      final s = PracticeScorer(ref);
      // Line 2 sung 250 ms behind the music.
      for (final p in sing(4.8, 7.5, (t) => refMidi(t - 0.25))) {
        s.add(p);
      }
      final line2 = s.lineResult(1);
      expect(line2.tokens.where((t) => t.issues.contains(TokenIssue.late)).length, greaterThanOrEqualTo(3));
      // Loop back to line 2 and sing it well: the pass is replaced.
      for (final p in sing(4.8, 7.5, refMidi)) {
        s.add(p);
      }
      expect(s.lineResult(1).problems, isEmpty);
      // Both passes over line 2 are logged; the second one is better.
      expect(s.linePasses[1], hasLength(2));
      expect(s.linePasses[1]![1], greaterThan(s.linePasses[1]![0]));
      expect(s.lineResult(0).attempted, isFalse);
      expect(s.overallScore(), greaterThan(85));
    });
  });
}
