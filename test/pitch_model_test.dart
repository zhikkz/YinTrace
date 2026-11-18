import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/dsp/swift_f0.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/pitch_model.dart';
import 'package:yintrace/src/separation/tensor_model.dart';

import 'support/python_ort_model.dart';
import 'support/synth_voice.dart';

/// A stand-in for the pitch model: for every frame of its input, 220 Hz
/// with a confidence that follows the input's level around the frame, and
/// a "pitch" that encodes the sum of the input over the frame's
/// neighbourhood (eight frames on each side, less than the model's
/// context), so that results depend on where a run starts and ends.
class _FakePitchModel implements TensorModel {
  int runs = 0;
  bool closed = false;
  final inputs = <int>[];

  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    expect(shape, [1, input.length]);
    runs++;
    inputs.add(input.length);
    return compute(input);
  }

  static Float32List compute(Float32List x) {
    final n = math.max(1, x.length ~/ SwiftF0.hop);
    final prefix = Float64List(x.length + 1);
    for (var i = 0; i < x.length; i++) {
      prefix[i + 1] = prefix[i] + x[i];
    }
    final out = Float32List(2 * n);
    for (var k = 0; k < n; k++) {
      final c = k * SwiftF0.hop;
      final a = (c - 8 * SwiftF0.hop).clamp(0, x.length), b = (c + 8 * SwiftF0.hop).clamp(0, x.length);
      out[k] = 220 + (prefix[b] - prefix[a]);
      var peak = 0.0;
      for (var i = c; i < math.min(x.length, c + SwiftF0.hop); i++) {
        peak = math.max(peak, x[i].abs());
      }
      out[n + k] = peak > 0.01 ? 0.9 : 0.1;
    }
    return out;
  }

  @override
  Future<void> close() async => closed = true;
}

Float32List _tone(double hz, double seconds, int sr, {double amp = 0.3, int harmonics = 8}) {
  final n = (seconds * sr).round();
  final x = Float32List(n);
  for (var i = 0; i < n; i++) {
    var v = 0.0;
    for (var h = 1; h <= harmonics; h++) {
      v += math.sin(2 * math.pi * hz * h * i / sr) / h;
    }
    x[i] = amp * v / 2;
  }
  return x;
}

void main() {
  final python = Platform.environment['PYTHON'] ?? 'python3';
  bool hasOrt;
  try {
    hasOrt = Process.runSync(python, ['-c', 'import onnxruntime, numpy']).exitCode == 0;
  } catch (_) {
    hasOrt = false;
  }
  final skipReal = hasOrt ? false : 'needs $python with onnxruntime and numpy (PYTHON selects the interpreter)';

  group('bundled pitch model', () {
    test('is the file the build script makes, and is in the app', () {
      final file = File(PitchModel.asset);
      expect(file.lengthSync(), PitchModel.bytes);
      expect('${crypto.sha256.convert(file.readAsBytesSync())}', PitchModel.sha256,
          reason: 'run `python tools/build_pitch_model.py build` and update PitchModel.sha256');
      expect(File('pubspec.yaml').readAsStringSync(), contains('- ${PitchModel.asset}'));
    });

    test('is copied out once, under a name of its content, replacing older ones', () async {
      final dir = Directory.systemTemp.createTempSync('pitch_model');
      addTearDown(() => dir.deleteSync(recursive: true));
      File('${dir.path}/swift_f0-000000000000.onnx').writeAsStringSync('an older model');
      File('${dir.path}/UVR-MDX-NET-Voc_FT-dynamic.onnx').writeAsStringSync('not ours');
      var loads = 0;
      Future<ByteData> load(String asset) async {
        loads++;
        final bytes = File(asset).readAsBytesSync();
        return ByteData.sublistView(bytes);
      }

      final path = await PitchModel.install(dir, load);
      expect(path, '${dir.path}/${PitchModel.fileName}');
      expect(File(path).readAsBytesSync(), File(PitchModel.asset).readAsBytesSync());
      expect(File('${dir.path}/swift_f0-000000000000.onnx').existsSync(), isFalse);
      expect(File('${dir.path}/UVR-MDX-NET-Voc_FT-dynamic.onnx').existsSync(), isTrue);
      expect(await PitchModel.install(dir, load), path);
      expect(loads, 1, reason: 'already there');
      await expectLater(
        PitchModel.install(Directory('${dir.path}/other'), (_) async => ByteData(PitchModel.bytes)),
        throwsStateError,
      );
    });

    test('a copy that was changed is written again, also one of the right length', () async {
      final dir = Directory.systemTemp.createTempSync('pitch_model');
      addTearDown(() => dir.deleteSync(recursive: true));
      final model = File(PitchModel.asset).readAsBytesSync();
      final copy = File('${dir.path}/${PitchModel.fileName}')
        ..writeAsBytesSync(Uint8List.fromList(model)..[model.length ~/ 2] ^= 0xff);
      expect(copy.lengthSync(), PitchModel.bytes);
      var loads = 0;
      Future<ByteData> load(String asset) async {
        loads++;
        return ByteData.sublistView(File(asset).readAsBytesSync());
      }

      expect(await PitchModel.install(dir, load), copy.path);
      expect(loads, 1, reason: 'the copy is not the model');
      expect(copy.readAsBytesSync(), model);
      expect(await PitchModel.install(dir, load), copy.path);
      expect(loads, 1, reason: 'now it is');
    });
  });

  group('SwiftF0', () {
    test('splits the joined output and treats digital silence as unvoiced', () async {
      final x = Float32List(16 * SwiftF0.hop);
      for (var i = 4 * SwiftF0.hop; i < x.length; i++) {
        x[i] = 0.2 * math.sin(i / 7);
      }
      x[SwiftF0.hop + 3] = 5e-4; // too quiet to count
      final frames = await SwiftF0(_FakePitchModel()).run(x);
      expect(frames.length, 16);
      expect(frames.hz.every((v) => v > 0), isTrue);
      for (var i = 0; i < 16; i++) {
        expect(frames.confidence[i], closeTo(i < 4 ? 0 : 0.9, 1e-6), reason: 'frame $i');
      }
      expect(() => SwiftF0(_BadModel()).run(x), throwsStateError);
    });

    test('a long recording in runs gives what one run over all of it does', () async {
      final rng = math.Random(4);
      final x = Float32List(SwiftF0.runFrames * SwiftF0.hop * 2 + 12345);
      for (var i = 0; i < x.length; i++) {
        x[i] = (rng.nextDouble() * 2 - 1) * 0.3;
      }
      final model = _FakePitchModel();
      final whole = await SwiftF0(model).run(x);
      model.runs = 0;
      final progress = <double>[];
      final parts = await SwiftF0(model).analyze(x, onProgress: progress.add);
      expect(model.runs, 3);
      expect(progress.last, 1);
      expect(parts.length, whole.length);
      for (var i = 0; i < whole.length; i++) {
        expect(parts.hz[i], closeTo(whole.hz[i], 1e-3), reason: 'frame $i');
        expect(parts.confidence[i], whole.confidence[i]);
      }
    });
  });

  group('with the real model', () {
    late PythonOrtModel model;
    setUpAll(() async {
      if (!hasOrt) return;
      model = await PythonOrtModel.start(PitchModel.asset, python: python);
    });
    tearDownAll(() async {
      if (hasOrt) await model.close();
    });

    test('sung notes at their pitch; silence and noise unvoiced', () async {
      const sr = 16000;
      final f0 = SwiftF0(model);
      for (final hz in [98.0, 220.0, 440.0, 880.0]) {
        final frames = await f0.run(_tone(hz, 0.6, sr));
        final mid = [for (var i = 10; i < frames.length - 10; i++) i];
        expect(mid.every((i) => frames.confidence[i] >= SwiftF0.voicedConfidence), isTrue, reason: '$hz Hz');
        for (final i in mid) {
          expect((hzToMidi(frames.hz[i]) - hzToMidi(hz)).abs() * 100, lessThan(15), reason: '$hz Hz frame $i');
        }
      }
      final silence = await f0.run(Float32List(sr));
      expect(silence.confidence.every((c) => c == 0), isTrue);
      final rng = math.Random(3);
      final noise = Float32List.fromList([for (var i = 0; i < sr; i++) (rng.nextDouble() * 2 - 1) * 0.2]);
      final n = await f0.run(noise);
      expect(n.confidence.where((c) => c >= SwiftF0.voicedConfidence).length, lessThan(3));
    }, skip: skipReal);

    group('offline, on a synthetic sung melody', () {
      final syl1 = sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64],
          durations: [0.32, 0.24, 0.32, 0.24, 0.32, 0.24, 0.32, 0.24, 0.32, 0.9], glides: {6: 64});
      final syl2 = sungLine('下雨了 记得带伞', 7.1, [67, 69, 67, 72, 71, 69, 67],
          durations: [0.28, 0.28, 0.6, 0.28, 0.28, 0.28, 0.6], pauses: {3: 0.45});
      final audio = synthVoice([...syl1, ...syl2], 12);
      final lrc = parseLrc('[00:01.00]夜里的风慢慢吹过窗台\n[00:07.00]下雨了 记得带伞\n');
      late PitchTrack track;
      late SongReference ref;
      setUpAll(() async {
        if (!hasOrt) return;
        track = await analyzePitchWithModel(audio, 44100, SwiftF0(model));
        ref = buildReference(track, lrc.lines);
      });

      test('the track follows the melody on the frames of the YIN track', () {
        final yin = analyzePitch(audio, 44100);
        expect(track.hopSeconds, yin.hopSeconds);
        expect(track.length, yin.length);
        expect(track.rmsDb, yin.rmsDb, reason: 'the same level');
        expect(track.spectralChange, yin.spectralChange, reason: 'the same change of sound');
        var good = 0, total = 0;
        for (final s in [...syl1, ...syl2]) {
          if (s.glideTo != null) continue;
          for (var x = s.start + 0.05; x < math.min(s.end - 0.03, s.start + 0.25); x += 0.01) {
            total++;
            if ((track.midiAt(x) - s.midi).abs() < 0.35) good++;
          }
        }
        expect(good / total, greaterThan(0.95));
        expect(track.midiAt(5.5), 0, reason: 'silence between the lines');
      }, skip: skipReal);

      test('characters land on their syllables', () {
        final truth = [...syl1, ...syl2];
        final tokens = ref.tokens.toList();
        expect(tokens.length, truth.length);
        var onTime = 0;
        for (var i = 0; i < tokens.length; i++) {
          if ((tokens[i].start - truth[i].start).abs() < 0.06) onTime++;
        }
        expect(onTime / tokens.length, greaterThanOrEqualTo(0.85),
            reason: [
              for (var i = 0; i < tokens.length; i++)
                '${tokens[i].text}:${tokens[i].start.toStringAsFixed(2)}/${truth[i].start.toStringAsFixed(2)}',
            ].join(' '));
        for (var i = 0; i < tokens.length; i++) {
          if (truth[i].glideTo != null) continue;
          expect(tokens[i].meanMidi, closeTo(truth[i].midi, 0.6), reason: tokens[i].text);
        }
        final melisma = ref.lines[0].tokens[6];
        expect(melisma.notes.length, greaterThanOrEqualTo(2));
        expect(melisma.notes.first.midi, closeTo(62, 0.6));
        expect(melisma.notes.last.midi, closeTo(64, 0.6));
      }, skip: skipReal);

      test('a quiet recording gives the model the same input', () async {
        // Without the absolute level gate (which both detectors apply to
        // the recording's own level), 40 dB quieter is the same track.
        const ungated = PitchAnalysisOptions(absoluteGateDb: -200);
        final loud = await analyzePitchWithModel(audio, 44100, SwiftF0(model), options: ungated);
        final quiet = Float32List.fromList([for (final v in audio) v * 0.01]);
        final q = await analyzePitchWithModel(quiet, 44100, SwiftF0(model), options: ungated);
        var same = 0, voiced = 0;
        for (var f = 0; f < loud.length; f++) {
          if (!loud.voiced(f)) continue;
          voiced++;
          if (q.voiced(f) && (q.midi[f] - loud.midi[f]).abs() < 0.01) same++;
        }
        expect(voiced, greaterThan(1000));
        expect(same / voiced, greaterThan(0.99));
      }, skip: skipReal);
    });

    group('import', () {
      late Directory tmp;
      setUp(() => tmp = Directory.systemTemp.createTempSync('yt_pitch_import'));
      tearDown(() => tmp.deleteSync(recursive: true));
      final syls = sungLine('雨点落在屋檐', 1.0, [60, 62, 64, 65, 67, 69]);
      const lyrics = '[00:01.00]雨点落在屋檐\n';

      Future<SongMeta> importWith(ImportPipeline pipeline, {bool Function()? isCancelled}) {
        final input = '${tmp.path}/vocal.wav';
        writeWavFile(input, synthVoice(syls, 4), 1, 44100);
        return pipeline.run(
          ImportRequest(
            audioPath: input,
            lyrics: lyrics,
            title: 'v',
            vocalsOnly: true,
            pitchModelPath: PitchModel.asset,
          ),
          isCancelled: isCancelled,
        );
      }

      test('measures the pitch with the model and says so', () async {
        final repo = SongRepository(Directory('${tmp.path}/songs'));
        final loaded = <String>[];
        final pipeline = ImportPipeline(
          audio: const WavAudioBackend(),
          repository: repo,
          loadModel: (path, {required inputName, required outputName, coreML}) async {
            loaded.add('$path $inputName $outputName');
            return _Unclosable(model);
          },
        );
        final meta = await importWith(pipeline);
        expect(loaded, ['${PitchModel.asset} audio pitch_confidence']);
        expect(meta.modelInfo[ImportPipeline.pitchInfo], PitchModel.name);
        expect(meta.modelInfo['pitchModelError'], isNull);
        final tokens = (await repo.loadReference(meta.id)).tokens.toList();
        expect(tokens.length, 6);
        for (var i = 0; i < tokens.length; i++) {
          expect(tokens[i].meanMidi, closeTo(syls[i].midi, 0.6), reason: tokens[i].text);
        }
      }, skip: skipReal);

      test('finishes the song with YIN when the model fails', () async {
        final repo = SongRepository(Directory('${tmp.path}/songs'));
        final pipeline = ImportPipeline(
          audio: const WavAudioBackend(),
          repository: repo,
          loadModel: (path, {required inputName, required outputName, coreML}) async => _BadModel(),
        );
        final meta = await importWith(pipeline);
        expect(meta.modelInfo[ImportPipeline.pitchInfo], 'YIN');
        expect(meta.modelInfo['pitchModelError'], contains('pitch model returned'));
        expect((await repo.loadReference(meta.id)).tokens.length, 6);
      });

      test('stopping during the pitch analysis stops the import', () async {
        final repo = SongRepository(Directory('${tmp.path}/songs'));
        var analysing = false;
        final pipeline = ImportPipeline(
          audio: const WavAudioBackend(),
          repository: repo,
          loadModel: (path, {required inputName, required outputName, coreML}) async {
            analysing = true;
            return _FakePitchModel();
          },
        );
        await expectLater(importWith(pipeline, isCancelled: () => analysing), throwsA(isA<SeparationCancelled>()));
        expect(await repo.list(), isEmpty);
      });
    });
  });
}

class _BadModel implements TensorModel {
  @override
  Future<Float32List> run(Float32List input, List<int> shape) async => Float32List(3);
  @override
  Future<void> close() async {}
}

/// Shares the test's model process with the pipeline, which closes what
/// it loads.
class _Unclosable implements TensorModel {
  _Unclosable(this.model);
  final TensorModel model;
  @override
  Future<Float32List> run(Float32List input, List<int> shape) => model.run(input, shape);
  @override
  Future<void> close() async {}
}
