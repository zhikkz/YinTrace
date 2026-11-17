// Practice with the pitch model measuring the singer, with the real native
// engine in offline mode.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/dsp/swift_f0.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/pitch_model.dart';
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/separation/tensor_model.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/python_ort_model.dart';
import 'support/synth_voice.dart';

const sr = 44100;

/// Counts its runs and whether it was closed; the pitch it reports is the
/// one of [inner] (or 0 Hz, unvoiced, without one).
class _CountingModel implements TensorModel {
  _CountingModel([this.inner]);
  final TensorModel? inner;
  int runs = 0;
  bool closed = false;

  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    runs++;
    final inner = this.inner;
    if (inner != null) return inner.run(input, shape);
    return Float32List(2 * (input.length ~/ SwiftF0.hop).clamp(1, 1 << 30));
  }

  @override
  Future<void> close() async => closed = true;
}

void main() {
  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];
  final python = Platform.environment['PYTHON'] ?? 'python3';
  bool hasOrt;
  try {
    hasOrt = Process.runSync(python, ['-c', 'import onnxruntime, numpy']).exitCode == 0;
  } catch (_) {
    hasOrt = false;
  }
  late Directory tmp;
  late SongRepository repo;
  late SongMeta meta;
  late Float32List voice;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('yt_practice_model');
    repo = SongRepository(Directory('${tmp.path}/songs'));
    voice = synthVoice([
      ...sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64]),
      ...sungLine('下雨了 记得带伞', 6.6, [67, 69, 67, 72, 71, 69, 67], pauses: {3: 0.4}),
    ], 11);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    meta = await ImportPipeline(
      audio: const WavAudioBackend(),
      repository: repo,
      loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
    ).run(ImportRequest(
      audioPath: '${tmp.path}/vocal.wav',
      lyrics: '[00:01.00]夜里的风慢慢吹过窗台\n[00:06.50]下雨了 记得带伞\n',
      title: '示例',
      vocalsOnly: true,
    ));
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  ModelPitchTracker? tracker;

  Future<PracticeSession> start(TensorModel model) async {
    final session = PracticeSession(
      meta: meta,
      reference: await repo.loadReference(meta.id),
      repository: repo,
      settings: AppSettings(null),
      engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
      decodeInBackground: false,
      pitchSource: ({required sampleRate, required options}) async =>
          tracker = ModelPitchTracker(sampleRate: sampleRate, model: SwiftF0(model), options: options),
    );
    await session.start();
    return session;
  }

  /// Plays the whole song with the original vocal at the microphone. The
  /// test renders far faster than real time: each model run finishes before
  /// the next audio callback, as it does on a phone.
  Future<void> sing(PracticeSession session) async {
    final e = session.engine!;
    session.play();
    while (e.isPlaying) {
      final at = e.positionFrame;
      final input = Float32List(512);
      for (var i = 0; i < 512 && at + i < voice.length; i++) {
        input[i] = voice[at + i];
      }
      e.render(512, input: input);
      session.tick();
      await tracker!.settle();
    }
    session.tick();
  }

  test('what the model measures in the background is scored, and the model is closed', () async {
    final model = _CountingModel();
    final session = await start(model);
    expect(session.pitchDetector, 'SwiftF0');
    await sing(session);
    expect(model.runs, greaterThan(100));
    expect(session.points.length, greaterThan(500), reason: 'every 16 ms frame of 11 s reached the trail');
    expect(session.points.every((p) => p.midi == 0), isTrue, reason: 'this model hears no pitch');
    session.dispose();
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(model.closed, isTrue);
  }, skip: lib == null ? 'needs YINTRACE_AUDIO_LIB' : false);

  test('singing the melody with the real model scores high', () async {
    final ort = await PythonOrtModel.start(PitchModel.asset, python: python);
    final model = _CountingModel(ort);
    final session = await start(model);
    await sing(session);
    final results = session.scorer.results();
    expect(results.every((r) => r.attempted), isTrue);
    for (final r in results) {
      expect(r.score, greaterThan(85), reason: 'line ${r.line.text}');
    }
    final voiced = session.points.where((p) => p.midi > 0).length;
    expect(voiced, greaterThan(300));
    session.dispose();
    await ort.close();
  }, skip: lib == null
      ? 'needs YINTRACE_AUDIO_LIB'
      : hasOrt
          ? false
          : 'needs $python with onnxruntime and numpy');
}
