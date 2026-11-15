import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';

import 'support/synth_voice.dart';

/// Example lyrics in the format the app accepts (written for these tests).
const exampleLyrics = '''
[00:12.40]夜里的风慢慢吹过窗台
[00:17.95]远处的灯一盏一盏亮开
[00:23.50]巷口的小店还没有打烊
[00:29.10]热汤的香气飘到街上
[00:35.80]下雨了 记得带伞
[00:39.20]路滑的地方慢一点走
[00:44.75]有人在等你回家吃饭
[00:50.30]桌上的菜热了又热
[01:12.60]下雨了 记得带伞
[01:16.00]淋湿了也别着急
[01:21.55]擦干头发 喝一杯茶
[01:27.10]明天又是晴朗的一天
''';

void main() {
  group('LRC parser', () {
    test('parses the example lyrics', () {
      final r = parseLrc(exampleLyrics);
      expect(r.errors, isEmpty);
      expect(r.lines.length, 12);
      expect(r.lines.first.start, closeTo(12.40, 1e-9));
      expect(r.lines.first.tokens.map((t) => t.text).join(), '夜里的风慢慢吹过窗台');
      expect(r.lines.first.end, closeTo(17.95, 1e-9));
      final l5 = r.lines[4];
      expect(l5.text, '下雨了 记得带伞');
      expect(l5.tokens.length, 7);
      expect(l5.tokens[3].text, '记');
      expect(l5.tokens[3].spaceBefore, isTrue);
      expect(l5.tokens[2].spaceBefore, isFalse);
      expect(r.lines.last.start, closeTo(87.10, 1e-9));
      expect(r.lines.last.end, isNull);
      // A line ends where the next one starts, also across an interlude.
      expect(r.lines[7].end, closeTo(72.60, 1e-9));
    });

    test('handles metadata, offsets, repeats, english and enhanced tags', () {
      final r = parseLrc('''
[ti:Song]
[offset:+500]
[00:10.00][00:30.5]Hello my friend, it's me
[00:20.00]<00:20.00>你<00:20.50>好
[00:25.00]
bogus line
''');
      expect(r.metadata['ti'], 'Song');
      expect(r.lines.length, 3);
      expect(r.lines[0].start, closeTo(9.5, 1e-9));
      expect(r.lines[0].tokens.map((t) => t.text).toList(), ['Hello', 'my', 'friend', "it's", 'me']);
      expect(r.lines[0].tokens[3].spaceBefore, isTrue);
      expect(r.lines[1].tokens[1].time, closeTo(20.0, 1e-9));
      // the empty [00:25.00] line ends the second line
      expect(r.lines[1].end, closeTo(24.5, 1e-9));
      expect(r.lines[2].start, closeTo(30.0, 1e-9));
      expect(r.errors.length, 1);
      expect(formatLrcTime(83.09), '01:23.09');
    });

    test('lines that share a time stamp: the first is sung, the rest is its translation', () {
      // Written for this test, the way players export bilingual lyrics.
      final r = parseLrc('''
[00:01.00]夜里的风慢慢吹过窗台
[00:01.00]The night wind slowly blows past the window
[00:05.00]远处的灯一盏一盏亮开
[00:05.000]Far away the lamps light up one by one
[00:05.00]（第三种语言）
[00:09.00][00:20.00]下雨了记得带伞
[00:09.00][00:20.00]Take an umbrella when it rains
''');
      expect(r.errors, isEmpty);
      expect(r.lines.map((l) => l.text), ['夜里的风慢慢吹过窗台', '远处的灯一盏一盏亮开', '下雨了记得带伞', '下雨了记得带伞']);
      expect(r.translations, 5);
      expect(r.lines[0].translation, 'The night wind slowly blows past the window');
      expect(r.lines[1].translation, 'Far away the lamps light up one by one / （第三种语言）');
      expect(r.lines[3].translation, 'Take an umbrella when it rains');
      // The first line ends where the next line to sing starts.
      expect(r.lines[0].end, closeTo(5, 1e-9));
      // Lyrics without translations are untouched.
      final plain = parseLrc(exampleLyrics);
      expect(plain.translations, 0);
      expect(plain.lines.every((l) => l.translation == null), isTrue);
    });

    test('lines with the same time keep the order they were written in', () {
      // Enough of them that an unstable sort would shuffle some pair.
      final text = StringBuffer();
      for (var i = 0; i < 40; i++) {
        final stamp = '[00:${(59 - i).toString().padLeft(2, '0')}.00]';
        text
          ..writeln('$stamp原文第${String.fromCharCode(0x4E00 + i)}句')
          ..writeln('${stamp}translation $i');
      }
      final r = parseLrc(text.toString());
      expect(r.lines, hasLength(40));
      expect(r.lines.every((l) => l.text.startsWith('原文') && l.translation!.startsWith('translation')), isTrue);
    });
  });

  group('pitch analysis + per character alignment', () {
    // Two lines: 10 characters (mix of unvoiced and voiced onsets, one
    // melisma) and a 7 character line with a pause at the space.
    final syl1 = sungLine('夜里的风慢慢吹过窗台', 1.12, [62, 64, 65, 67, 65, 64, 62, 60, 62, 64],
        durations: [0.32, 0.24, 0.32, 0.24, 0.32, 0.24, 0.32, 0.24, 0.32, 0.9], glides: {6: 64});
    final syl2 = sungLine('下雨了 记得带伞', 7.1, [67, 69, 67, 72, 71, 69, 67],
        durations: [0.28, 0.28, 0.6, 0.28, 0.28, 0.28, 0.6], pauses: {3: 0.45});
    final audio = synthVoice([...syl1, ...syl2], 12);
    final track = analyzePitch(audio, 44100);
    final lrc = parseLrc('[00:01.00]夜里的风慢慢吹过窗台\n[00:07.00]下雨了 记得带伞\n');
    final ref = buildReference(track, lrc.lines);

    test('pitch track follows the synthetic melody', () {
      var good = 0, total = 0;
      for (final s in [...syl1, ...syl2]) {
        if (s.glideTo != null) continue;
        for (var x = s.start + 0.05; x < math.min(s.end - 0.03, s.start + 0.25); x += 0.01) {
          total++;
          if ((track.midiAt(x) - s.midi).abs() < 0.35) good++;
        }
      }
      expect(good / total, greaterThan(0.95));
      // silence between the lines is unvoiced
      expect(track.midiAt(5.5), 0);
    });

    test('characters land on their syllables', () {
      expect(ref.lines.length, 2);
      final truth = [...syl1, ...syl2];
      final tokens = ref.tokens.toList();
      expect(tokens.length, truth.length);
      var onTime = 0;
      for (var i = 0; i < tokens.length; i++) {
        if ((tokens[i].start - truth[i].start).abs() < 0.06) onTime++;
      }
      expect(onTime / tokens.length, greaterThanOrEqualTo(0.85),
          reason: [for (var i = 0; i < tokens.length; i++) '${tokens[i].text}:${tokens[i].start.toStringAsFixed(2)}/${truth[i].start.toStringAsFixed(2)}'].join(' '));
      for (var i = 0; i < tokens.length; i++) {
        if (truth[i].glideTo != null) continue;
        expect(tokens[i].meanMidi, closeTo(truth[i].midi, 0.6), reason: tokens[i].text);
      }
    });

    test('melisma becomes two notes; reference serialises', () {
      final melisma = ref.lines[0].tokens[6];
      expect(melisma.text, '吹');
      expect(melisma.notes.length, greaterThanOrEqualTo(2));
      expect(melisma.notes.first.midi, closeTo(62, 0.6));
      expect(melisma.notes.last.midi, closeTo(64, 0.6));
      final copy = SongReference.fromJson(jsonDecode(jsonEncode(ref.toJson())) as Map<String, dynamic>);
      expect(copy.tokens.length, ref.tokens.length);
      expect(copy.lines[1].tokens[3].spaceBefore, isTrue);
      expect(copy.noteAt(syl2[3].start + 0.1)!.midi, closeTo(72, 0.6));
      expect(copy.lineIndexAt(8.0), 1);
      final range = copy.pitchRange;
      expect(range.$1, closeTo(60, 0.7));
      expect(range.$2, closeTo(72, 0.7));
    });

    test('a translation under each line does not take the melody away from it', () {
      final plain = buildReference(track, lrc.lines);
      final bilingual = parseLrc(
        '[00:01.00]夜里的风慢慢吹过窗台\n[00:01.00]The night wind slowly blows past the window\n'
        '[00:07.00]下雨了 记得带伞\n[00:07.00]Take an umbrella when it rains\n',
      );
      final r = buildReference(track, bilingual.lines);
      expect(r.language.code, 'zh', reason: 'the language is that of the lines to sing');
      expect(r.lines, hasLength(2));
      for (var i = 0; i < 2; i++) {
        expect(r.lines[i].tokens.where((t) => t.hasPitch).length, plain.lines[i].tokens.length);
        expect(
          [for (final t in r.lines[i].tokens) t.start],
          [for (final t in plain.lines[i].tokens) t.start],
          reason: 'aligned exactly as without the translation',
        );
      }
      expect(r.lines[0].translation, 'The night wind slowly blows past the window');
      final copy = SongReference.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
      expect(copy.lines[1].translation, 'Take an umbrella when it rains');
      expect(copy.lines[1].text, '下雨了 记得带伞');
    });

    test('a line without singing gets evenly spaced, pitchless tokens', () {
      // Line 1 ends near 4.8 s and line 2 starts at 7.1 s; nothing is sung
      // in between, so the extra line gets no pitch and the sung lines are
      // not disturbed.
      final silent = parseLrc('[00:01.00]夜里的风慢慢吹过窗台\n[00:05.60]没有声音\n[00:07.00]下雨了 记得带伞\n');
      final r = buildReference(track, silent.lines);
      final tokens = r.lines[1].tokens;
      expect(tokens.length, 4);
      expect(tokens.where((t) => t.notes.isNotEmpty), isEmpty);
      expect(tokens.every((t) => t.confidence == 0), isTrue);
      expect(r.lines[0].tokens.last.start, closeTo(syl1.last.start, 0.06));
      expect(r.lines[2].tokens.first.start, closeTo(syl2.first.start, 0.06));
    });
  });
}
