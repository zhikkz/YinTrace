// Listening to the original singer and to the take, and switching between
// them, with the real native engine in offline mode.
import 'dart:io';
import 'dart:math' as math;
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

  /// What the live microphone alone sounds like (the file tracks muted): the
  /// RMS of the left channel once the monitor has settled. The monitor
  /// high-passes the mic, so the mic plays a tone (whole periods per
  /// callback), not DC. Both ears must hear the same.
  final mic = Float32List.fromList([for (var i = 0; i < 256; i++) 0.05 * math.sin(2 * math.pi * i / 128)]);
  double monitorLevel() {
    final e = session.engine!;
    for (var slot = 0; slot < 3; slot++) {
      e.setTrackGain(slot, 0);
    }
    var out = Float32List(0);
    for (var i = 0; i < 8; i++) {
      out = e.render(mic.length, input: mic);
    }
    var sum = 0.0;
    for (var i = 0; i < out.length; i += 2) {
      expect(out[i + 1], out[i]);
      sum += out[i] * out[i];
    }
    return math.sqrt(sum / mic.length);
  }

  test('a short take late in the song plays at its original absolute position', () {
    final e = session.engine!;
    final take = session.take!;
    const first = 7 * sr;
    take.addAudio(Float32List(256)..fillRange(0, 256, 0.25), first, 0);
    session.listenBack(line: 1);
    expect(session.listening, ListenKind.take);
    e.seekFrame(first - 32);
    final out = e.render(64);
    expect(out.take(64), everyElement(closeTo(0, 1e-5)));
    expect(out.skip(64), everyElement(closeTo(0.25, 1e-4)));
  }, skip: lib == null);

  test('live monitoring follows practice, pause and listening without changing the level', () {
    expect(session.monitorAvailable, isTrue); // offline test route
    expect(session.monitorEnabled, isFalse);
    session.play();
    expect(monitorLevel(), 0);
    session.settings.monitorLevel = 0.25; // unity gain
    session.setMonitorEnabled(true);
    // Every resume starts the monitor afresh, so the same mic sounds the same.
    final level = monitorLevel();
    expect(level, greaterThan(0.02));
    session.pause();
    expect(monitorLevel(), 0);
    session.play();
    expect(monitorLevel(), closeTo(level, 1e-9));
    // Capture an actual take, then check both listening modes with a live mic.
    session.applyMix();
    run(5.5);
    expect(session.canListenBack(), isTrue);
    session.listenOriginal(line: 0);
    expect(monitorLevel(), 0);
    session.listenBack(line: 0);
    expect(monitorLevel(), 0);
    session.stopListening();
    expect(monitorLevel(), 0); // still paused
    session.play();
    expect(monitorLevel(), closeTo(level, 1e-9));
    session.setMonitorEnabled(false);
    expect(monitorLevel(), 0);
    expect(session.settings.monitorLevel, 0.25);
  }, skip: lib == null);

  test('the monitor level slider sets the gain after compression', () {
    session.play();
    session.settings.monitorLevel = 0.25;
    session.setMonitorEnabled(true);
    final unity = monitorLevel();
    // A -29 dBFS tone, just inside the compressor's knee: a little under unity.
    expect(unity, inInclusiveRange(0.7 * 0.05 / math.sqrt2, 0.05 / math.sqrt2));
    for (final (level, gain) in [(0.5, 4.0), (0.75, 9.0), (0.1, 0.16)]) {
      session.settings.monitorLevel = level;
      session.applyMix();
      expect(monitorLevel() / unity, closeTo(gain, gain * 1e-3), reason: 'slider $level');
    }
    session.settings.monitorLevel = 0;
    session.applyMix();
    expect(monitorLevel(), 0);
  }, skip: lib == null);

  test('monitoring is silenced on backgrounding and disarmed when headphones are lost', () {
    session.play();
    session.setMonitorEnabled(true);
    final level = monitorLevel();
    expect(level, greaterThan(0.02));
    session.suspend();
    expect(monitorLevel(), 0);
    session.resume();
    expect(monitorLevel(), 0);
    session.play();
    expect(monitorLevel(), closeTo(level, 1e-9));
    final e = session.engine!;
    e.signalAudioEvent(AudioEvents.routeChanged);
    expect(monitorLevel(), 0); // native mute, before the app sees the event
    session.tick();
    expect(session.monitorEnabled, isTrue); // a safe route reconfiguration
    expect(monitorLevel(), closeTo(level, 1e-9));
    e.signalAudioEvent(AudioEvents.routeChanged | AudioEvents.deviceLost);
    expect(monitorLevel(), 0);
    session.tick();
    expect(session.monitorEnabled, isFalse);
    e.signalAudioEvent(AudioEvents.routeChanged); // headphones reconnected
    session.tick();
    session.play();
    expect(monitorLevel(), 0);
    session.setMonitorEnabled(true);
    expect(monitorLevel(), closeTo(level, 1e-9));
    // A quick resume before tick() must also consume the pending loss.
    e.signalAudioEvent(AudioEvents.deviceLost);
    session.play();
    expect(session.monitorEnabled, isFalse);
    expect(monitorLevel(), 0);
  }, skip: lib == null);

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

  test('replaying the take works after playback reaches the end of the song', () {
    session.play();
    run(20);
    expect(session.finished, isTrue);
    session.finished = false;

    // With real-device audio latency > 100 ms, `position` stays more than
    // 50 ms short of the track end even after playback reaches it.
    session.settings.latencyOffsetMs = 140;
    session.applyMix();

    session.listenBack();
    final e = session.engine!;
    expect(session.listening, ListenKind.take);
    expect(session.isPlaying, isTrue);

    var ticksNotified = 0;
    void count() => ticksNotified++;
    session.addListener(count);
    var stoppedTickNotified = false;
    for (var n = 0; n < 20 * sr && e.isPlaying; n += 512) {
      e.render(512, input: Float32List(512));
      ticksNotified = 0;
      final justStopped = !e.isPlaying;
      session.tick();
      if (justStopped) stoppedTickNotified = ticksNotified > 0;
    }
    expect(e.isPlaying, isFalse);
    expect(e.positionSeconds, closeTo(e.lengthSeconds, 0.01));
    expect(session.position, lessThan(e.lengthSeconds - 0.05));
    expect(stoppedTickNotified, isTrue);
    ticksNotified = 0;
    for (var i = 0; i < 5; i++) {
      session.tick();
    }
    expect(ticksNotified, 0);
    session.removeListener(count);

    // Pressing play again rewinds to the start of the take and renders audio.
    session.togglePlay();
    expect(session.isPlaying, isTrue);
    final startFrame = e.positionFrame;
    expect(startFrame / sr, lessThan(1.0));
    var peak = 0.0;
    for (var i = 0; i < 200 && e.isPlaying; i++) {
      final out = e.render(512, input: Float32List(512));
      for (final s in out) {
        if (s.abs() > peak) peak = s.abs();
      }
      if (e.positionSeconds >= 2.0) break;
    }
    expect(e.isPlaying, isTrue);
    expect(e.positionFrame, greaterThan(startFrame + 2048));
    expect(peak, greaterThan(0.05));

    // Leaving listening right after hitting the end (before tick() runs) must
    // not carry the review endCount into practice and mark the run finished.
    for (var n = 0; n < 20 * sr && e.isPlaying; n += 512) {
      e.render(512, input: Float32List(512));
    }
    expect(e.isPlaying, isFalse);
    session.stopListening();
    session.tick();
    expect(session.reviewing, isFalse);
    expect(session.finished, isFalse);
  }, skip: lib == null);

  test('listening back to a line before the end notifies once on pause and replays', () {
    session.play();
    run(5.5);
    session.listenBack(line: 0);
    final e = session.engine!;
    var ticksNotified = 0;
    void count() => ticksNotified++;
    session.addListener(count);
    var pauseTickNotified = false;
    for (var n = 0; n < 20 * sr && e.isPlaying; n += 512) {
      e.render(512, input: Float32List(512));
      ticksNotified = 0;
      session.tick();
      if (!e.isPlaying) pauseTickNotified = ticksNotified > 0;
    }
    expect(e.isPlaying, isFalse);
    expect(pauseTickNotified, isTrue);
    ticksNotified = 0;
    for (var i = 0; i < 5; i++) {
      session.tick();
    }
    expect(ticksNotified, 0);
    session.removeListener(count);

    session.togglePlay();
    expect(session.isPlaying, isTrue);
    expect(e.positionSeconds, closeTo(math.max(0.0, session.reference.lines[0].start - 1.2), 0.02));
    final startFrame = e.positionFrame;
    e.render(2048, input: Float32List(2048));
    expect(session.isPlaying, isTrue);
    expect(e.positionFrame, startFrame + 2048);
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
