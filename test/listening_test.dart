// Listening to the original singer and to the take, and switching between
// them, with the real native engine in offline mode.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/practice/segment_player.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/synth_voice.dart';

const sr = 44100;

void main() {
  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];
  late Directory tmp;
  late SongRepository repo;
  late PracticeSession session;
  late Float32List voice;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('yt_listen');
    repo = SongRepository(Directory('${tmp.path}/songs'));
    final syllables = [
      ...sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64]),
      ...sungLine('下雨了 记得带伞', 6.6, [67, 69, 67, 72, 71, 69, 67], pauses: {3: 0.4}),
    ];
    voice = synthVoice(syllables, 11);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    final meta =
        await ImportPipeline(
          audio: const WavAudioBackend(),
          repository: repo,
          loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
        ).run(
          ImportRequest(
            audioPath: '${tmp.path}/vocal.wav',
            lyrics: '[00:01.00]夜里的风慢慢吹过窗台\n[00:06.50]下雨了 记得带伞\n',
            title: '示例',
            vocalsOnly: true,
          ),
        );
    session = PracticeSession(
      meta: meta,
      reference: await repo.loadReference(meta.id),
      repository: repo,
      settings: AppSettings(null),
      engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
      decodeInBackground: false,
    );
    await session.start();
  });

  tearDown(() {
    session.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Plays [seconds] of audio with the singer (the original vocal) at the mic.
  void run(double seconds) {
    final e = session.engine!;
    final frames = (seconds * sr).round();
    for (var n = 0; n < frames && (e.isPlaying || session.reviewing); n += 512) {
      final at = e.positionFrame;
      final input = Float32List(512);
      for (var i = 0; i < 512 && at + i < voice.length; i++) {
        input[i] = voice[at + i];
      }
      e.render(512, input: input);
      session.tick();
      if (!e.isPlaying) break;
    }
  }

  test('the original singer is heard loud, then practice waits at that line', () {
    session.setLoopLine(0);
    session.play();
    run(4.6); // line 0 sung once, before the loop wraps
    final line0 = session.scorer.lineResult(0).score;
    expect(line0, greaterThan(80));
    session.listenOriginal(line: 1);
    expect(session.listening, ListenKind.original);
    run(20); // to its end
    expect(session.reviewing, isFalse);
    expect(session.isPlaying, isFalse);
    expect(session.loopLine, 1, reason: 'the loop moves to the line heard');
    final line1 = session.reference.lines[1];
    expect(session.engine!.positionSeconds, closeTo(line1.start - 1.0, 0.02));
    expect(session.scorer.lineResult(0).score, line0, reason: 'nothing scored while listening');
  }, skip: lib == null);

  test('from the original singer straight to the take keeps the scores', () {
    session.play();
    run(5.5);
    final line0 = session.scorer.lineResult(0).score;
    session.listenOriginal(line: 0);
    run(0.5);
    session.listenBack(line: 0);
    expect(session.listening, ListenKind.take);
    expect(session.scorer.lineResult(0).score, line0);
    session.stopListening();
    expect(session.reviewing, isFalse);
    expect(session.engine!.positionSeconds, closeTo(session.reference.lines[0].start - 1.0, 0.02));
    expect(session.scorer.lineResult(0).score, line0);
  }, skip: lib == null);

  test('the pitch editor plays again after the output was lost', () {
    final player = SegmentPlayer(
      engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
      configureSession: false,
    );
    final tone = Float32List(4410)..fillRange(0, 4410, 0.25);
    player.play(tone: tone);
    expect(player.engine!.render(64)[0], closeTo(0.25, 1e-3));
    player.engine!.signalAudioEvent(AudioEvents.deviceLost); // headphones unplugged
    expect(player.engine!.render(64)[0], 0);
    player.play(tone: tone);
    expect(player.engine!.render(64)[0], closeTo(0.25, 1e-3));
    player.dispose();
  }, skip: lib == null);
}
