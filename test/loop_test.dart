// Looping a line, or singing one again, must not touch the lines next to
// it: not their scores, not the practice record, not the take. With the
// real native engine in offline mode; the lines are as close together as
// in a real verse (lines seconds apart hide all of this).
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/ui/score_trend.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/synth_voice.dart';

const sr = 44100;

void main() {
  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];
  late Directory tmp;
  late SongRepository repo;
  late SongMeta meta;
  late PracticeSession session;
  late Float32List voice;

  /// Three lines of a verse; [gap] seconds between the end of one and the
  /// start of the next.
  Future<void> open({double gap = 0.57}) async {
    tmp = Directory.systemTemp.createTempSync('yt_loop');
    repo = SongRepository(Directory('${tmp.path}/songs'));
    final line1 = sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64]);
    final line2 = sungLine('远处的灯一盏一盏亮开', line1.last.end + gap, [64, 65, 67, 69, 67, 65, 64, 62, 64, 65]);
    final line3 = sungLine('下雨了记得带伞', line2.last.end + gap, [67, 69, 67, 72, 71, 69, 67]);
    final seconds = line3.last.end + 1.6;
    voice = synthVoice([...line1, ...line2, ...line3], seconds);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    String stamp(double t) => '[00:${(t - 0.12).toStringAsFixed(2).padLeft(5, '0')}]';
    meta = await ImportPipeline(
      audio: const WavAudioBackend(),
      repository: repo,
      loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
    ).run(ImportRequest(
      audioPath: '${tmp.path}/vocal.wav',
      lyrics: '${stamp(line1.first.start)}夜里的风慢慢吹过窗台\n'
          '${stamp(line2.first.start)}远处的灯一盏一盏亮开\n'
          '${stamp(line3.first.start)}下雨了记得带伞\n',
      title: '示例',
      vocalsOnly: true,
    ));
    session = PracticeSession(
      meta: meta,
      reference: await repo.loadReference(meta.id),
      repository: repo,
      settings: AppSettings(null),
      engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
      decodeInBackground: false,
    );
    await session.start();
  }

  tearDown(() {
    session.dispose();
    tmp.deleteSync(recursive: true);
  });

  /// Plays [seconds]; the singer (the original vocal) sings only in
  /// [from, to).
  void run(double seconds, {double from = 0, double to = 1e9}) {
    final e = session.engine!;
    for (var n = 0; n < seconds * sr && e.isPlaying; n += 512) {
      final at = e.positionFrame;
      final input = Float32List(512);
      for (var i = 0; i < 512 && at + i < voice.length; i++) {
        final t = (at + i) / sr;
        if (t >= from && t < to) input[i] = voice[at + i];
      }
      e.render(512, input: input);
      session.tick();
    }
  }

  /// Plays to the end of the song, singing everything.
  void runToEnd() {
    run(60);
    expect(session.finished, isTrue);
  }

  double takeRms(double from, double to) {
    final x = session.take!.samples!;
    var s = 0.0;
    for (var i = (from * sr).round(); i < (to * sr).round(); i++) {
      s += x[i] * x[i];
    }
    return math.sqrt(s / ((to - from) * sr));
  }

  for (final gap in [0.57, 0.26]) {
    test('looping one line does not score the lines next to it (lines $gap s apart)', () async {
      await open(gap: gap);
      final line = session.reference.lines[1];
      session.setLoopLine(1);
      session.play();
      run(2.5 * (line.end - line.start + 1.8), from: line.start - 0.1, to: line.end + 0.1);
      expect(session.displayPoints.any((p) => p.midi > 0), isTrue);
      expect(
        session.displayPoints.map((p) => p.time),
        everyElement(lessThanOrEqualTo(session.position)),
        reason: 'the previous pass should not leave pitch points ahead of playback',
      );
      final r = session.scorer.results();
      expect(r[1].score, greaterThan(90));
      expect(r[0].attempted, isFalse, reason: 'line 0 was not sung: ${r[0].tokens.map((t) => t.summary).toList()}');
      expect(r[2].attempted, isFalse, reason: 'line 2 was not sung: ${r[2].tokens.map((t) => t.summary).toList()}');
      expect(session.scorer.overallScore(r), greaterThan(90));
      // The record holds the looped line only.
      final record = (await session.save())!;
      expect(record.lineScores.keys, [1]);
      expect(record.loopLine, 1);
      expect(record.score, greaterThan(90));
    }, skip: lib == null);
  }

  test('singing a line again keeps the line before it, in the score and in the take', () async {
    await open();
    final lines = session.reference.lines;
    session.play();
    run(lines[1].end + 0.2); // lines 0 and 1
    final last = lines[0].tokens.last;
    final score = session.scorer.lineResult(0).score;
    final rms = takeRms(last.start, last.end);
    expect(rms, greaterThan(0.05));
    session.seekToLine(1); // 重唱这一句
    run(lines[1].end - lines[1].start + 1.3, from: lines[1].start - 0.1);
    expect(session.scorer.lineResult(0).score, score);
    expect(session.scorer.lineResult(1).score, greaterThan(90));
    expect(takeRms(last.start, last.end), closeTo(rms, 1e-4), reason: 'the last character of line 0 stays in the take');
    // ...and what was sung of it, as listening back shows it.
    expect(session.take!.pointAt(last.start + 0.15)?.midi, closeTo(last.notes.first.midi, 0.5));
  }, skip: lib == null);

  test('looping a line after the whole song keeps the other lines and their part of the take', () async {
    await open();
    final lines = session.reference.lines;
    session.play();
    runToEnd();
    final before = [for (final r in session.scorer.results()) r.score];
    expect(before.every((s) => s > 90), isTrue);
    final overall = session.scorer.overallScore();
    final tail = lines[0].tokens.last, head = lines[2].tokens.first;
    final rmsTail = takeRms(tail.start, tail.end), rmsHead = takeRms(head.start, head.end);

    // Two passes of line 1 on its own, nobody singing in the music around it.
    session.setLoopLine(1);
    session.seekToLine(1);
    session.play();
    run(2 * (lines[1].end - lines[1].start + 1.8) + 0.5, from: lines[1].start - 0.1, to: lines[1].end + 0.1);
    final after = session.scorer.results();
    expect(after[0].score, before[0]);
    expect(after[2].score, before[2], reason: 'the lines after the looped one stay');
    expect(after[1].score, greaterThan(90));
    expect(session.scorer.overallScore(after), closeTo(overall, 2));
    expect(takeRms(tail.start, tail.end), closeTo(rmsTail, 1e-4));
    expect(takeRms(head.start, head.end), closeTo(rmsHead, 1e-4));
    // The looped line itself is in the take.
    final mid = lines[1].tokens[4];
    expect(takeRms(mid.start, mid.end), greaterThan(0.05));
  }, skip: lib == null);

  test('one run is one record, however often the scores are looked at', () async {
    await open();
    final lines = session.reference.lines;
    session.play();
    run(lines[0].end + 0.4); // line 0 only
    final first = (await session.save())!; // 查看评分
    expect(first.lineScores.keys, [0]);
    expect(first.wholeSong, isFalse, reason: 'a third of the song is not a run through it');
    var stored = await repo.load(meta.id);
    expect(stored.practiceCount, 1);
    expect(stored.bestScore, isNull, reason: 'one line sung well is not the best score');
    expect(wholeSongScores(await repo.loadHistory(meta.id)), isEmpty);

    // The run goes on to the end: the same record, now the whole song.
    session.play();
    runToEnd();
    final whole = (await session.save())!;
    expect(whole.at, first.at);
    expect(whole.wholeSong, isTrue);
    expect(whole.coverage, closeTo(1, 0.05));
    expect((await session.save())!.at, first.at, reason: 'looking again stores nothing new');
    var history = await repo.loadHistory(meta.id);
    expect(history, hasLength(1));
    expect(history.single.lineScores.keys, [0, 1, 2]);
    stored = await repo.load(meta.id);
    expect(stored.practiceCount, 1);
    expect(stored.bestScore, closeTo(whole.score, 1e-9));
    expect(whole.score, greaterThan(90));

    // Looping line 1 is a run of its own: one more record, with that line
    // only. Lines 0 and 2, sung once, are in the history once.
    session.setLoopLine(1);
    session.seekToLine(1);
    session.play();
    run(lines[1].end - lines[1].start + 2.4, from: lines[1].start - 0.1, to: lines[1].end + 0.1);
    await session.save();
    run(lines[1].end - lines[1].start + 1.8, from: lines[1].start - 0.1, to: lines[1].end + 0.1);
    final loop = (await session.save())!;
    expect(loop.loopLine, 1);
    expect(loop.lineScores.keys, [1]);
    history = await repo.loadHistory(meta.id);
    expect(history, hasLength(2));
    expect(lineScores(history, 0), hasLength(1));
    expect(lineScores(history, 1), hasLength(2));
    expect(lineScores(history, 2), hasLength(1));
    expect(wholeSongScores(history), [history.first.score]);
    stored = await repo.load(meta.id);
    expect(stored.practiceCount, 2);
    expect(stored.bestScore, closeTo(whole.score, 1e-9));
  }, skip: lib == null);

  test('上一句 and 下一句 move one line at a time, also while paused in a lead-in', () async {
    // Lines 0.26 s apart: one second before a line starts, the line before
    // it is still sounding.
    await open(gap: 0.26);
    final lines = session.reference.lines;
    final e = session.engine!;
    expect(session.currentLine, 0);
    session.seekToLine(session.currentLine + 1); // 下一句
    expect(e.positionSeconds, closeTo(lines[1].start - 1.0, 0.02));
    expect(lines[0].end, greaterThan(session.position), reason: 'line 0 still sounds here');
    expect(session.currentLine, 1, reason: 'the line jumped to, not the one still sounding');
    session.seekToLine(session.currentLine + 1); // 下一句 again, still paused
    expect(session.currentLine, 2);
    expect(e.positionSeconds, closeTo(lines[2].start - 1.0, 0.02));
    session.seekToLine(session.currentLine - 1); // 上一句
    expect(session.currentLine, 1);
    session.seekToLine(session.currentLine); // 重唱这一句: the same line
    expect(session.currentLine, 1);
    expect(e.positionSeconds, closeTo(lines[1].start - 1.0, 0.02));

    // Played on, the line playing is in focus again.
    session.play();
    run(lines[2].start - session.position + 0.3);
    expect(session.currentLine, 2);
    session.pause();

    // The progress bar moves to a time, not to a line.
    session.seek(lines[1].start - 0.5);
    expect(session.currentLine, 0);

    // Looping: the looped line, from its lead-in on; 下一句 / 上一句 move
    // the loop one line at a time.
    session.setLoopLine(1);
    expect(session.currentLine, 1);
    session.seekToLine(session.currentLine + 1);
    expect([session.loopLine, session.currentLine], [2, 2]);
    session.seekToLine(session.currentLine - 1);
    session.seekToLine(session.currentLine - 1);
    expect([session.loopLine, session.currentLine], [0, 0]);
  }, skip: lib == null);

  test('an interlude shows the line coming up; skipping it leaves time to get ready', () async {
    await open(gap: 7);
    final lines = session.reference.lines;
    session.play();
    run(lines[0].end + 0.2);
    expect(session.shownLine, 0, reason: 'its last character just ended');
    run(PracticeSession.lineOverSeconds);
    expect(session.shownLine, 1, reason: 'the interlude leads in to the line coming up');
    expect(session.currentLine, 0, reason: '重唱这一句 is still the line just sung');
    // 跳过间奏: to three seconds before the line shown.
    session.seekToLine(session.shownLine, leadIn: 3);
    expect(session.engine!.positionSeconds, closeTo(lines[1].start - 3, 0.02));
    expect([session.currentLine, session.shownLine], [1, 1]);
    run(3.6, from: lines[1].start - 0.1, to: lines[1].end + 0.1);
    expect(session.scorer.lineResult(1).attempted, isTrue);
  }, skip: lib == null);

  test('right after singing a line, the buttons are about that line', () async {
    await open(gap: 2);
    final lines = session.reference.lines;
    session.play();
    run(lines[0].end + 1.0); // a second into the gap after line 0
    expect(session.shownLine, 1, reason: 'the lyrics show the line coming up');
    session.pause();
    // 重唱这一句: line 0 again.
    session.seekToLine(session.currentLine);
    expect(session.engine!.positionSeconds, closeTo(math.max(0, lines[0].start - 1.0), 0.02));
    // From the gap again: 单句循环 loops line 0, 下一句 goes to line 1.
    session.seek(lines[0].end + 1.0);
    session.setLoopLine(session.currentLine);
    expect(session.loopLine, 0);
    session.setLoopLine(null);
    session.seek(lines[0].end + 1.0);
    session.seekToLine(session.currentLine + 1);
    expect(session.engine!.positionSeconds, closeTo(lines[1].start - 1.0, 0.02));
    expect(session.currentLine, 1);
  }, skip: lib == null);

  test('a run nobody sang in is not kept', () async {
    await open();
    final lines = session.reference.lines;
    session.play();
    run(lines[1].end + 0.3, to: 0); // the song plays, the microphone is silent
    expect(session.scorer.lineResult(0).attempted, isTrue, reason: 'played counts as attempted for the scores');
    expect(await session.save(), isNull);
    expect(await repo.loadHistory(meta.id), isEmpty);
    expect((await repo.load(meta.id)).practiceCount, 0);
    expect(session.take!.voicedSeconds(), 0);
    // Singing after that is a run like any other.
    session.seekToLine(0);
    run(lines[0].end - lines[0].start + 1.3, from: lines[0].start - 0.1);
    expect(session.take!.voicedSeconds(), greaterThan(2));
    final record = (await session.save())!;
    expect(record.lineScores.keys, contains(0));
    expect(await repo.loadHistory(meta.id), hasLength(1));
  }, skip: lib == null);

  test('从头再唱 starts another run from the top, playing', () async {
    await open();
    final lines = session.reference.lines;
    session.play();
    run(lines[1].end + 0.3); // lines 0 and 1
    final first = (await session.save())!;
    session.pause();
    session.restart();
    expect(session.isPlaying, isTrue);
    expect(session.engine!.positionSeconds, lessThan(0.05));
    run(lines[0].end + 0.3);
    final second = (await session.save())!;
    expect(second.at, isNot(first.at));
    expect(second.lineScores.keys, [0]);
    final history = await repo.loadHistory(meta.id);
    expect(history.map((r) => r.lineScores.keys.toList()), [
      [0, 1],
      [0],
    ]);
  }, skip: lib == null);

  test('the line heard from the original singer is the one shown, before and after', () async {
    await open(gap: 0.26);
    final lines = session.reference.lines;
    session.listenOriginal(line: 2);
    expect(session.position, lessThan(lines[2].start));
    expect(session.currentLine, 2);
    run(20); // to the end of the line
    expect(session.reviewing, isFalse);
    expect(session.engine!.positionSeconds, closeTo(lines[2].start - 1.0, 0.02));
    expect(session.currentLine, 2, reason: 'ready to sing the line just heard');
  }, skip: lib == null);

  test('the song from the top again is another run', () async {
    await open();
    session.play();
    runToEnd();
    final first = (await session.save())!;
    session.play(); // from the top; this time nobody sings the last line
    run(session.reference.lines[1].end + 0.3);
    final second = (await session.save())!;
    expect(second.at, isNot(first.at));
    expect(second.lineScores.keys, [0, 1]);
    final history = await repo.loadHistory(meta.id);
    expect(history.map((r) => r.lineScores.length), [3, 2]);
    expect(history.first.score, first.score, reason: 'the first run stays as it was');
  }, skip: lib == null);
}
