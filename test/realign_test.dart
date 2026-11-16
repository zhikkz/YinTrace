// Editing the lyrics of a song: lines whose words did not change keep the
// user's pitch corrections and their practice scores, wherever they moved.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/ui/score_trend.dart';

import 'support/synth_voice.dart';

RefLine line(int index, String text, double start) => RefLine(
  index: index,
  text: text,
  lrcStart: start,
  tokens: [
    for (final (k, c) in text.split('').indexed)
      RefToken(text: c, start: start + 0.4 * k, end: start + 0.4 * k + 0.3, notes: []),
  ],
);

List<RefLine> lines(List<(String, double)> l) => [for (final (i, (text, start)) in l.indexed) line(i, text, start)];

void main() {
  group('matchLines', () {
    test('a line added, removed or rewritten leaves the others paired', () {
      final old = lines([('风吹过', 1), ('下雨了', 5), ('天晴了', 9)]);
      expect(matchLines(old, lines([('风吹过', 1), ('下雨了', 5), ('天晴了', 9)])), {0: 0, 1: 1, 2: 2});
      expect(matchLines(old, lines([('夜深了', 0), ('风吹过', 1), ('下雨了', 5), ('天晴了', 9)])), {0: 1, 1: 2, 2: 3});
      expect(matchLines(old, lines([('风吹过', 1), ('天晴了', 9)])), {0: 0, 2: 1});
      expect(matchLines(old, lines([('风吹过', 1), ('下雪了', 5), ('天晴了', 9)])), {0: 0, 2: 2});
      expect(matchLines(old, lines([('花开了', 3)])), isEmpty);
      expect(matchLines([], old), isEmpty);
    });

    test('only the time stamps or the punctuation changed: the same lines', () {
      final old = lines([('风吹过', 1), ('下雨了', 5)]);
      final retimed = [line(0, '风吹过', 1.4), RefLine(index: 1, text: '下雨了！', lrcStart: 5.2, tokens: old[1].tokens)];
      expect(matchLines(old, retimed), {0: 0, 1: 1});
    });

    test('of the same words sung several times, the nearest in time are paired', () {
      // A chorus sung three times; the second time is removed.
      final old = lines([('下雨了', 10), ('天晴了', 14), ('下雨了', 30), ('下雨了', 50)]);
      expect(matchLines(old, lines([('下雨了', 10), ('天晴了', 14), ('下雨了', 50)])), {0: 0, 1: 1, 3: 2});
      // ...or the first one is, and the time stamps of the others were moved a little.
      expect(matchLines(old, lines([('天晴了', 14.2), ('下雨了', 30.3), ('下雨了', 49.8)])), {1: 0, 2: 1, 3: 2});
    });
  });

  test('a practice record follows its lines', () {
    final whole = PracticeRecord(at: DateTime(2026, 11, 1), score: 80, lineScores: {0: 95, 1: 40, 2: 70}, coverage: 1);
    final moved = whole.remapped({0: 1, 2: 3})!;
    expect(moved.lineScores, {1: 95, 3: 70});
    expect([moved.score, moved.coverage, moved.at, moved.wholeSong], [80, 1, whole.at, true]);
    final loop = PracticeRecord(at: DateTime(2026, 11, 2), score: 60, lineScores: {1: 60}, loopLine: 1);
    expect(loop.remapped({0: 1, 2: 3}), isNull, reason: 'the looped line is gone');
    final kept = loop.remapped({1: 4})!;
    expect([kept.loopLine, kept.lineScores], [4, {4: 60.0}]);
  });

  group('re-aligning a song', () {
    late Directory tmp;
    late SongRepository repo;
    late SongMeta meta;
    const first = '[00:01.00]夜里的风慢慢吹过窗台\n';
    const rest = '[00:05.00]远处的灯一盏一盏亮开\n[00:09.00]下雨了记得带伞\n';

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('yt_realign');
      repo = SongRepository(Directory('${tmp.path}/songs'));
      final voice = synthVoice([
        ...sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64]),
        ...sungLine('远处的灯一盏一盏亮开', 5.12, [64, 65, 67, 69, 67, 65, 64, 62, 64, 65]),
        ...sungLine('下雨了记得带伞', 9.12, [67, 69, 67, 72, 71, 69, 67]),
      ], 13);
      writeWavFile('${tmp.path}/vocal.wav', voice, 1, 44100);
      // The first line was forgotten when the song was imported.
      meta = await ImportPipeline(
        audio: const WavAudioBackend(),
        repository: repo,
        loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
      ).run(ImportRequest(audioPath: '${tmp.path}/vocal.wav', lyrics: rest, title: '示例', vocalsOnly: true));
      // One character of each line corrected, and two practice runs.
      final ref = await repo.loadReference(meta.id);
      ref.lines[0].tokens[2].transpose(-12);
      ref.lines[1].tokens[4].skip = true;
      await repo.saveReference(meta.id, ref);
      await repo.addPractice(meta.id, PracticeRecord(at: DateTime(2026, 11, 1), score: 70, lineScores: {0: 95, 1: 40}));
      await repo.addPractice(
        meta.id,
        PracticeRecord(at: DateTime(2026, 11, 2), score: 60, lineScores: {1: 60}, loopLine: 1, coverage: 0.4),
      );
    });
    tearDown(() => tmp.deleteSync(recursive: true));

    test('a line added before the others: corrections and scores move with their lines', () async {
      final before = await repo.loadReference(meta.id);
      await realignSong(repo, meta.id, first + rest);
      final ref = await repo.loadReference(meta.id);
      expect(ref.lines.map((l) => l.text), ['夜里的风慢慢吹过窗台', '远处的灯一盏一盏亮开', '下雨了记得带伞']);
      expect(ref.lines[0].tokens.where((t) => t.corrected), isEmpty);
      final moved = ref.lines[1].tokens[2];
      expect(moved.shift, -12);
      expect(moved.notes.first.midi, closeTo(before.lines[0].tokens[2].notes.first.midi, 0.3));
      expect(ref.lines[1].tokens.where((t) => t.corrected), hasLength(1));
      expect(ref.lines[2].tokens[4].skip, isTrue);
      expect(ref.lines[2].tokens.where((t) => t.corrected), hasLength(1));

      final history = await repo.loadHistory(meta.id);
      expect(lineScores(history, 0), isEmpty, reason: 'the new line was never sung');
      expect(lineScores(history, 1), [95]);
      expect(lineScores(history, 2), [40, 60]);
      expect(history[1].loopLine, 2);
      // The first run was the whole song as it was then, and still is one.
      expect(history[0].coverage, closeTo(1, 1e-9));
      expect(wholeSongScores(history), [70]);
      expect((await repo.load(meta.id)).lyrics, first + rest);
    });

    test('a start set by hand stays with its line', () async {
      // “灯” set 0.1 s late by hand, in the line that will move down.
      var ref = await repo.loadReference(meta.id);
      final lamp = ref.lines[0].tokens[3];
      final pin = lamp.start + 0.1;
      ref = buildReference(await repo.loadPitchTrack(meta.id), parseLrc(rest).lines, pins: {(0, 3): pin})
        ..applyCorrectionsFrom(ref);
      await repo.saveReference(meta.id, ref);
      await realignSong(repo, meta.id, first + rest);
      ref = await repo.loadReference(meta.id);
      expect(ref.lines[1].tokens[3].text, '灯');
      expect(ref.lines[1].tokens[3].pinned, pin);
      expect(ref.lines[1].tokens[3].corrected, isTrue);
      expect(ref.tokens.where((t) => t.pinned != null), hasLength(1));
      // Rewritten, the line loses it.
      await realignSong(repo, meta.id, '$first[00:05.00]远处的灯一盏一盏亮了\n[00:09.00]下雨了记得带伞\n');
      expect((await repo.loadReference(meta.id)).tokens.where((t) => t.pinned != null), isEmpty);
    });

    test('a removed line takes its scores with it; a rewritten one starts over', () async {
      await realignSong(repo, meta.id, '[00:09.00]下雨了记得带伞\n');
      var history = await repo.loadHistory(meta.id);
      expect(history, hasLength(2));
      expect(lineScores(history, 0), [40, 60]);
      expect(history[1].loopLine, 0);
      expect((await repo.loadReference(meta.id)).lines[0].tokens[4].skip, isTrue);
      // One character changed: not the line that was practised.
      await realignSong(repo, meta.id, '[00:09.00]下雪了记得带伞\n');
      history = await repo.loadHistory(meta.id);
      expect(history.map((r) => r.score), [70], reason: 'the loop of the old line is gone, the whole run stays');
      expect(lineScores(history, 0), isEmpty);
      expect((await repo.loadReference(meta.id)).corrected, isFalse);
    });

    test('new time stamps alone change nothing', () async {
      final stored = File(repo.pathFor(meta.id, SongRepository.historyFile)).readAsStringSync();
      await realignSong(repo, meta.id, '[00:05.10]远处的灯一盏一盏亮开\n[00:09.05]下雨了，记得带伞\n');
      expect(File(repo.pathFor(meta.id, SongRepository.historyFile)).readAsStringSync(), stored);
      final ref = await repo.loadReference(meta.id);
      expect(ref.lines[0].tokens[2].shift, -12);
      expect(ref.lines[1].tokens[4].skip, isTrue);
    });
  });
}
