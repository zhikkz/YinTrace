import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/lyrics_language.dart';
import 'package:yintrace/src/analysis/pinyin_initials.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';

import 'support/synth_voice.dart';

// Lyrics written for these tests.
const englishLyrics = '''
[00:01.00]Morning comes over the river
[00:06.50]Carry the light on your shoulder
''';

const japaneseLyrics = '''
[00:01.00]きょうも空(そら)はあおい
[00:06.00]まっすぐ歩(ある)いてゆこう
''';

/// Sings [tokens], each a list of syllables (MIDI, voiceless onset?), one
/// after another from [start]. Returns the syllables and each token's start
/// (the start of its first vowel).
(List<Syl>, List<double>) singTokens(
  double start,
  List<List<(double, bool)>> tokens, {
  double dur = 0.3,
  Map<int, double> pauses = const {},
}) {
  final syls = <Syl>[];
  final starts = <double>[];
  var t = start;
  for (var k = 0; k < tokens.length; k++) {
    t += pauses[k] ?? 0;
    for (var j = 0; j < tokens[k].length; j++) {
      final (midi, unvoiced) = tokens[k][j];
      if (syls.isNotEmpty && unvoiced) t += 0.07;
      if (j == 0) starts.add(t);
      final onsetGap = syls.isEmpty || unvoiced || (j == 0 && pauses.containsKey(k));
      syls.add(Syl(t, t + dur, midi, unvoicedOnset: onsetGap));
      t += dur;
    }
  }
  return (syls, starts);
}

void expectOnTime(List<RefToken> tokens, List<double> truth, {double within = 0.08, double share = 0.85}) {
  expect(tokens.length, truth.length);
  var good = 0;
  for (var i = 0; i < tokens.length; i++) {
    if ((tokens[i].start - truth[i]).abs() < within) good++;
  }
  expect(
    good / tokens.length,
    greaterThanOrEqualTo(share),
    reason: [
      for (var i = 0; i < tokens.length; i++)
        '${tokens[i].text}:${tokens[i].start.toStringAsFixed(2)}/${truth[i].toStringAsFixed(2)}',
    ].join(' '),
  );
}

void main() {
  group('tokenizer', () {
    test('english: words, spaces are not pauses, punctuation is', () {
      final t = tokenize("Hold on, the night is young");
      expect(t.map((x) => x.text), ['Hold', 'on', 'the', 'night', 'is', 'young']);
      expect(t.map((x) => x.spaceBefore), [false, true, true, true, true, true]);
      expect(t.map((x) => x.pauseBefore), [false, false, true, false, false, false]);
    });

    test('chinese: a space still is a pause', () {
      final t = tokenize('下雨了 记得带伞');
      expect(t[3].text, '记');
      expect(t[3].spaceBefore, isTrue);
      expect(t[3].pauseBefore, isTrue);
      expect(t[2].pauseBefore, isFalse);
    });

    test('japanese: small kana, sokuon and long vowels join the kana before', () {
      expect(tokenize('きょうはまっすぐ').map((x) => x.text), ['きょ', 'う', 'は', 'まっ', 'す', 'ぐ']);
      expect(tokenize('ラーメンとジュース').map((x) => x.text), ['ラー', 'メ', 'ン', 'と', 'ジュー', 'ス']);
      // 々 repeats the kanji before it: a unit of its own.
      expect(tokenize('時々').map((x) => x.text), ['時', '々']);
    });

    test('japanese: a hiragana reading in brackets after kanji is ruby', () {
      final t = tokenize('明日（あした）へ心(こころ)を');
      expect(t.map((x) => x.text), ['明日', 'へ', '心', 'を']);
      expect(t[0].reading, 'あした');
      expect(t[2].reading, 'こころ');
      expect(t[1].reading, isNull);
      // Not ruby: katakana or Latin in brackets are sung.
      expect(tokenize('君（ラララ）').map((x) => x.text), ['君', 'ラ', 'ラ', 'ラ']);
      expect(tokenize('夢(ah ah)').map((x) => x.text), ['夢', 'ah', 'ah']);
    });

    test('enhanced LRC word times survive ruby and kana joins', () {
      final t = tokenize('<00:01.00>心(こころ)<00:02.00>きょ<00:02.50>う');
      expect(t.map((x) => x.text), ['心', 'きょ', 'う']);
      expect(t[0].time, 1.0);
      expect(t[1].time, 2.0);
      expect(t[2].time, 2.5);
    });
  });

  group('language', () {
    test('is detected from the lyrics', () {
      expect(detectLyricsLanguage(parseLrc(englishLyrics).lines), LyricsLanguage.english);
      expect(detectLyricsLanguage(parseLrc(japaneseLyrics).lines), LyricsLanguage.japanese);
      expect(detectLanguage(['夜里的风慢慢吹过窗台', '下雨了 记得带伞 baby']), LyricsLanguage.chinese);
      expect(detectLanguage(['我の歌']), LyricsLanguage.chinese, reason: 'one stray kana is not Japanese');
      expect(LyricsLanguage.english.unit, '词');
      expect(LyricsLanguage.japanese.unit, '字');
    });

    test('english syllables', () {
      final cases = {
        'beautiful': 3,
        'love': 1,
        'little': 2,
        'smile': 1,
        'the': 1,
        'comes': 1,
        'changes': 2,
        'kisses': 2,
        'loved': 1,
        'wanted': 2,
        'river': 2,
        'shoulder': 2,
        'your': 1,
        "don't": 1,
        'eyes': 1,
      };
      cases.forEach((w, n) => expect(englishSyllables(w), n, reason: w));
    });

    test('japanese morae and onsets', () {
      expect(kanaMorae('きょう'), 2);
      expect(kanaMorae('まっすぐ'), 3.5);
      final heart = tokenize('心(こころ)').single;
      expect(tokenWeight(heart, LyricsLanguage.japanese), 3);
      expect(tokenOnsetClass(heart, LyricsLanguage.japanese), OnsetClass.unvoiced);
      final dream = tokenize('夢(ゆめ)').single;
      expect(tokenOnsetClass(dream, LyricsLanguage.japanese), OnsetClass.vowel);
      // Without a reading: an average kanji, no guess from Mandarin.
      expect(tokenWeight(const LyricToken('空'), LyricsLanguage.japanese), kanjiMorae);
      expect(tokenOnsetClass(const LyricToken('空'), LyricsLanguage.japanese), OnsetClass.unknown);
      expect(tokenOnsetClass(const LyricToken('空'), LyricsLanguage.chinese), onsetClassOf('空'));
      expect(tokenOnsetClass(const LyricToken('が'), LyricsLanguage.japanese), OnsetClass.voiced);
      expect(tokenOnsetClass(const LyricToken('か'), LyricsLanguage.japanese), OnsetClass.unvoiced);
      expect(tokenOnsetClass(const LyricToken('ナ'), LyricsLanguage.japanese), OnsetClass.voiced);
      expect(tokenOnsetClass(const LyricToken('を'), LyricsLanguage.japanese), OnsetClass.vowel);
    });

    test('english onsets', () {
      final c = {
        'the': OnsetClass.voiced,
        'think': OnsetClass.unvoiced,
        'my': OnsetClass.voiced,
        'on': OnsetClass.vowel,
        'you': OnsetClass.vowel,
        'sky': OnsetClass.unvoiced,
        'when': OnsetClass.vowel,
        'very': OnsetClass.voiced,
      };
      c.forEach((w, cls) => expect(tokenOnsetClass(LyricToken(w), LyricsLanguage.english), cls, reason: w));
    });
  });

  group('alignment', () {
    test('english words land on their first syllable', () {
      final (s1, t1) = singTokens(1.12, [
        [(64, false), (62, false)], // Mor-ning
        [(67, true)], // comes
        [(65, false), (64, false)], // o-ver
        [(61, false)], // the
        [(59, false), (62, false)], // ri-ver
      ]);
      final (s2, t2) = singTokens(6.6, [
        [(67, true), (69, false)], // Car-ry
        [(67, false)], // the
        [(72, false)], // light
        [(70, false)], // on
        [(68, false)], // your
        [(66, true), (63, false)], // shoul-der
      ]);
      final track = analyzePitch(synthVoice([...s1, ...s2], 11), 44100);
      final ref = buildReference(track, parseLrc(englishLyrics).lines);
      expect(ref.language, LyricsLanguage.english);
      expectOnTime(ref.tokens.toList(), [...t1, ...t2]);
      // A two-syllable word keeps both of its notes.
      final morning = ref.lines[0].tokens[0];
      expect(morning.text, 'Morning');
      expect(morning.notes.length, greaterThanOrEqualTo(2));
      expect(ref.lines[0].tokenText, 'Morning comes over the river');
    });

    test('japanese kana and kanji with readings land on their morae', () {
      final (s1, t1) = singTokens(1.12, [
        [(64, true)], // きょ
        [(66, false)], // う
        [(68, false)], // も
        [(70, true), (67, false)], // 空(そら)
        [(66, true)], // は
        [(63, false)], // あ
        [(61, false)], // お
        [(65, false)], // い
      ]);
      final (s2, t2) = singTokens(
        6.1,
        [
          [(62, false)], // まっ
          [(64, true)], // す
          [(66, false)], // ぐ
          [(68, false), (65, false)], // 歩(ある)
          [(63, false)], // い
          [(61, true)], // て
          [(64, false)], // ゆ
          [(66, true)], // こ
          [(68, false)], // う
        ],
        pauses: {1: 0.1},
      );
      final track = analyzePitch(synthVoice([...s1, ...s2], 11), 44100);
      final ref = buildReference(track, parseLrc(japaneseLyrics).lines);
      expect(ref.language, LyricsLanguage.japanese);
      expect(ref.lines[0].tokens.map((t) => t.text), ['きょ', 'う', 'も', '空', 'は', 'あ', 'お', 'い']);
      expectOnTime(ref.tokens.toList(), [...t1, ...t2]);
      // The kanji read with two morae spans both of them.
      final sky = ref.lines[0].tokens[3];
      expect(sky.notes.first.midi, closeTo(70, 0.6));
      expect(sky.notes.last.midi, closeTo(67, 0.6));
    });

    test('the language is stored with the reference', () {
      final ref = SongReference(lines: const [], duration: 1, language: LyricsLanguage.japanese);
      final copy = SongReference.fromJson(jsonDecode(jsonEncode(ref.toJson())) as Map<String, dynamic>);
      expect(copy.language, LyricsLanguage.japanese);
      // Older songs have no language field: Chinese.
      expect(SongReference.fromJson({'duration': 1, 'lines': []}).language, LyricsLanguage.chinese);
    });
  });
}
