import 'dart:convert';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/scoring.dart';
import 'package:yintrace/src/practice/take_recorder.dart';
import 'package:yintrace/src/ui/import_page.dart';
import 'package:yintrace/src/ui/library_page.dart';
import 'package:yintrace/src/ui/results_sheet.dart';
import 'package:yintrace/src/ui/score_trend.dart';
import 'package:yintrace/src/ui/theme.dart';

Float32List ramp(int n, double v) => Float32List(n)..fillRange(0, n, v);

UserPoint at(double t, [double midi = 60]) => UserPoint(t, midi, PitchVerdict.great, 0);

void main() {
  group('TakeRecorder', () {
    test('places audio where it was heard and keeps the latest take', () {
      final take = TakeRecorder(sampleRate: 1000, lengthFrames: 10000);
      expect(take.isEmpty, isTrue);
      take.addAudio(ramp(100, 0.5), 2050, 50); // heard at frame 2000
      expect(take.samples![1999], 0);
      expect(take.samples![2000], 0.5);
      expect(take.samples![2099], 0.5);
      expect(take.samples![2100], 0);
      expect(take.startSeconds, 2.0);
      expect(take.endSeconds, 2.1);
      expect(take.covers(1.0, 2.05), isTrue);
      expect(take.covers(2.2, 3.0), isFalse);
      final version = take.version;
      take.addAudio(ramp(100, -0.25), 2000, 0); // sung again
      expect(take.samples![2050], closeTo(-0.25, 1e-7));
      expect(take.version, greaterThan(version));
      // Blocks before the start or past the end of the song are cut.
      take.addAudio(ramp(100, 0.1), 30, 50);
      expect(take.samples![0], closeTo(0.1, 1e-7));
      take.addAudio(ramp(100, 0.2), 9990, 0);
      expect(take.samples![9999], closeTo(0.2, 1e-7));
      expect(take.endSeconds, 10.0);
    });

    test('short passages late in a long song allocate only touched blocks', () {
      const sr = 44100;
      final take = TakeRecorder(sampleRate: sr, lengthFrames: 600 * sr);
      const at = 500 * sr;
      take.addAudio(ramp(6000, 0.5), at, 0);
      final capacity = take.allocatedFrames;
      expect(capacity, lessThan(16000));
      take.addAudio(ramp(6000, 0.25), at, 0);
      expect(take.allocatedFrames, capacity);
      final clip = take.readFrames(at - 1, at + 6001);
      expect(clip.first, 0);
      expect(clip.last, 0);
      expect(clip.skip(1).take(6000), everyElement(0.25));
      take.addAudio(ramp(50, -0.5), 20, 0);
      expect(take.allocatedFrames, lessThan(21000));
      expect(take.readFrames(10000, 10100), everyElement(0));
      expect(take.startFrame, 20);
      expect(take.endFrame, at + 6000);
    });

    test('a passage sung again replaces only that part of the pitch trail', () {
      final take = TakeRecorder(sampleRate: 1000, lengthFrames: 1000);
      for (var i = 0; i < 100; i++) {
        take.addPoint(at(i * 0.01, 60)); // 0 .. 0.99 s
      }
      // Seek back to 0.3 s and sing 0.3 .. 0.5 s again, higher.
      for (var i = 30; i <= 50; i++) {
        take.addPoint(at(i * 0.01 + 0.001, 62));
      }
      final times = [for (final p in take.points) p.time];
      expect(times, orderedEquals([...times]..sort()));
      expect(take.points.length, 100);
      expect(take.pointAt(0.2)!.midi, 60);
      expect(take.pointAt(0.4)!.midi, 62);
      expect(take.pointAt(0.8)!.midi, 60, reason: 'the rest of the earlier take stays');
      expect(take.pointAt(5.0), isNull);
    });

    test('the time a voice was heard follows passages sung again', () {
      final take = TakeRecorder(sampleRate: 1000, lengthFrames: 1000);
      for (var i = 0; i < 100; i++) {
        take.addPoint(at(i * 0.01, i < 50 ? 60 : 0)); // a voice for 0 .. 0.5 s
      }
      expect(take.voicedSeconds(), closeTo(0.5, 1e-9));
      for (var i = 20; i <= 40; i++) {
        take.addPoint(at(i * 0.01 + 0.001, 0)); // 0.2 .. 0.4 s again, silent
      }
      expect(take.voicedSeconds(), closeTo(0.29, 1e-9));
      for (var i = 75; i < 85; i++) {
        take.addPoint(at(i * 0.01 + 0.001, 62)); // 0.75 .. 0.85 s again, sung
      }
      expect(take.voicedSeconds(), closeTo(0.39, 1e-9));
      expect(take.points.where((p) => p.midi > 0).length, 39);
    });
  });

  group('score trend', () {
    final t0 = DateTime(2026, 11, 1);
    PracticeRecord rec(double score, Map<int, double> lines, {int? loop}) =>
        PracticeRecord(at: t0, score: score, lineScores: lines, loopLine: loop);
    final history = [
      rec(62, {0: 60, 1: 64}),
      rec(70, {1: 75}, loop: 1),
      rec(71, {0: 70, 1: 72}),
      rec(78, {0: 80, 1: 76}),
    ];

    test('whole runs and per-line scores', () {
      expect(wholeSongScores(history), [62, 71, 78]);
      expect(lineScores(history, 1), [64, 75, 72, 76]);
      expect(lineScores(history, 0), [60, 70, 80]);
      expect(lineScores(history, 5), isEmpty);
      expect(wholeSongScores([for (var i = 0; i < 30; i++) rec(i.toDouble(), {})]).first, 10);
    });

    testWidgets('chart summarises the progress', (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Scaffold(
            body: Column(
              children: [
                ScoreTrend(history: history),
                LineScoreSparkline(scores: lineScores(history, 1)),
              ],
            ),
          ),
        ),
      );
      expect(find.text('得分趋势'), findsOneWidget);
      expect(find.text('最近 78 分，比第一次高 16 分'), findsOneWidget);
      expect(find.textContaining('另有 1 次单句循环'), findsOneWidget);
    });
  });

  group('results', () {
    // Two lines, one note per character.
    SongReference twoLines() {
      RefLine line(int index, String text, double start, List<double> midis) {
        final tokens = [
          for (var k = 0; k < midis.length; k++)
            RefToken(
              text: text[k],
              start: start + k * 0.5,
              end: start + k * 0.5 + 0.4,
              notes: [RefNote(start: start + k * 0.5, end: start + k * 0.5 + 0.4, midi: midis[k])],
            ),
        ];
        return RefLine(index: index, text: text, lrcStart: start, tokens: tokens);
      }

      return SongReference(
        lines: [line(0, '夜里的风', 1, [60, 62, 64, 65]), line(1, '下雨了', 4, [67, 65, 64])],
        duration: 8,
      );
    }

    /// Sings [ref] from [from] to [to] seconds: in tune, except [flat]
    /// semitones low in line 1.
    void sing(PracticeScorer scorer, SongReference ref, {double from = 0.5, double to = 6, double flat = 0.8}) {
      for (var t = from; t < to; t += 0.01) {
        final note = ref.noteAt(t);
        final inLine1 = t >= ref.lines[1].start - 0.2;
        final midi = note == null ? 0.0 : note.midi - (inLine1 ? flat : 0);
        scorer.add(LivePitch(songTime: t, clockTime: t, midi: midi, levelDb: -20, playing: true, aperiodicity: 0.05));
      }
    }

    /// Opens the results of [scorer] the way the practice page does; what
    /// the sheet closes with ends up in [closedWith].
    ResultsAction? closedWith;
    Future<void> open(WidgetTester tester, PracticeScorer scorer) async {
      closedWith = null;
      await tester.pumpWidget(
        MaterialApp(
          theme: buildTheme(Brightness.light),
          home: Builder(
            builder: (context) => Scaffold(
              body: TextButton(
                onPressed: () async => closedWith = await showModalBottomSheet<ResultsAction>(
                  context: context,
                  isScrollControlled: true,
                  builder: (_) => ResultsSheet(scorer: scorer),
                ),
                child: const Text('评分'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('评分'));
      await tester.pumpAndSettle();
    }

    testWidgets('the weakest line sung is the next step; a tapped character opens its line', (tester) async {
      final ref = twoLines();
      final scorer = PracticeScorer(ref);
      sing(scorer, ref);
      final weak = scorer.lineResult(1).score;
      expect(weak, lessThan(80));
      expect(scorer.lineResult(0).score, greaterThan(80));

      ResultsAction? popped;
      Future<void> tapAndClose(Finder f) async {
        await tester.tap(f);
        await tester.pumpAndSettle();
        popped = closedWith;
      }

      await open(tester, scorer);
      expect(find.text('先练第 2 句（${weak.round()} 分）'), findsOneWidget);
      expect(find.text('从头再唱一遍'), findsOneWidget);
      await tapAndClose(find.text('先练第 2 句（${weak.round()} 分）'));
      expect(popped, isA<LoopLineAction>().having((a) => a.line, 'line', 1));

      await open(tester, scorer);
      await tapAndClose(find.text('从头再唱一遍'));
      expect(popped, isA<RestartAction>());

      // A flat character: the tile opens its line.
      await open(tester, scorer);
      await tester.ensureVisible(find.text('下').last);
      await tapAndClose(find.text('下').last);
      expect(popped, isA<LoopLineAction>().having((a) => a.line, 'line', 1));
    });

    testWidgets('while looping a line: its passes, go on, or back to the whole song', (tester) async {
      final ref = twoLines();
      final scorer = PracticeScorer(ref)..onlyLine = 1;
      sing(scorer, ref, from: 3.2, to: 5.8, flat: 0.8);
      scorer.startPass(3.2, fromLine: 1);
      sing(scorer, ref, from: 3.2, to: 5.8, flat: 0.1);
      expect(scorer.linePasses[1], hasLength(2));

      await open(tester, scorer);
      expect(find.text('单句循环 · 第 2 句'), findsOneWidget);
      expect(find.textContaining('这一句唱了 2 遍：'), findsOneWidget);
      expect(find.text('继续练这一句'), findsOneWidget);
      expect(find.text('不循环了，回到整首'), findsOneWidget);
      expect(find.textContaining('先练第'), findsNothing, reason: 'the line being looped is the one to practise');
      await tester.tap(find.text('继续练这一句'));
      await tester.pumpAndSettle();
      expect(closedWith, isA<ContinueLoopAction>());
      await open(tester, scorer);
      await tester.tap(find.text('不循环了，回到整首'));
      await tester.pumpAndSettle();
      expect(closedWith, isA<WholeSongAction>());
    });
  });

  group('pages', () {
    test('a lyrics file reads as UTF-8 or UTF-16; other encodings are refused, not garbled', () {
      const lrc = '[ti:夜航]\n[00:01.00]夜里的风';
      final utf16le = [0xFF, 0xFE, for (final u in lrc.codeUnits) ...[u & 0xFF, u >> 8]];
      final utf16be = [0xFE, 0xFF, for (final u in lrc.codeUnits) ...[u >> 8, u & 0xFF]];
      expect(decodeLyricsFile(utf8.encode(lrc)), lrc);
      expect(decodeLyricsFile([0xEF, 0xBB, 0xBF, ...utf8.encode(lrc)]), lrc);
      expect(decodeLyricsFile(utf16le), lrc);
      expect(decodeLyricsFile(utf16be), lrc);
      // "[00:01.00]夜里" in GBK.
      expect(decodeLyricsFile([...'[00:01.00]'.codeUnits, 0xD2, 0xB9, 0xC0, 0xEF]), isNull);
      expect(decodeLyricsFile([0x49, 0x44, 0x33, 0x00, 0x00]), isNull, reason: 'an mp3, not text');
    });

    test('when a song was last practised reads the way people say it', () {
      final now = DateTime(2026, 11, 17, 9, 30);
      expect(practicedWhen(DateTime(2026, 11, 17, 0, 5), now), '今天练过');
      expect(practicedWhen(DateTime(2026, 11, 16, 23, 50), now), '昨天练过');
      expect(practicedWhen(DateTime(2026, 11, 13, 12), now), '4 天前练过');
      expect(practicedWhen(DateTime(2026, 10, 2), now), '10 月 2 日练过');
      expect(practicedWhen(DateTime(2025, 12, 30), now), '2025 年 12 月练过');
    });
  });

  group('import progress', () {
    test('travels between isolates', () {
      const p = ImportProgress(
        ImportStage.removingHarmony,
        0.5,
        0.7,
        done: 12,
        total: 104,
        remaining: Duration(seconds: 95),
      );
      final q = ImportProgress.fromMap(p.toMap());
      expect([q.stage, q.stageFraction, q.overall, q.done, q.total, q.remaining], [
        p.stage,
        p.stageFraction,
        p.overall,
        12,
        104,
        const Duration(seconds: 95),
      ]);
      expect(ImportProgress.fromMap(const ImportProgress(ImportStage.decoding, 0, 0).toMap()).remaining, isNull);
    });

    test('remaining time reads in whole minutes', () {
      expect(importRemainingText(null), '正在估算剩余时间…');
      expect(importRemainingText(const Duration(seconds: 40)), '预计不到 1 分钟');
      expect(importRemainingText(const Duration(seconds: 61)), '预计还需约 2 分钟');
      expect(importRemainingText(const Duration(minutes: 5)), '预计还需约 5 分钟');
    });

    test('karaoke window follows the memory the system reports', () {
      const fiveMinutes = 5 * 60 * 44100;
      expect(ImportPipeline.vrWindowFor(null, fiveMinutes), 512);
      expect(ImportPipeline.vrWindowFor(3000 * 1000 * 1000, fiveMinutes), 512);
      expect(ImportPipeline.vrWindowFor(1000 * 1000 * 1000, fiveMinutes), 320);
    });
  });
}
