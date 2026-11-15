// Where the aligner puts characters whose start is hard to see (issue #9:
// near the end of a line the start of a character went late, and the
// character before took the beginning of its voice). The pitch tracks are
// built by hand, so that each case shows one thing.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';

/// The frame step of [analyzePitch].
const _hop = 128 / 22050;

/// One sung character: voiced from [start] to [end] at [midi] ([midi2] from
/// [split] on), after [gap] seconds of a voiceless consonant. A level dip
/// of [dip] dB at its start stands for a voiced consonant (m, n, l, r).
class _Char {
  const _Char(this.start, this.end, this.midi, {this.gap = 0, this.midi2, this.split, this.dip = 0});
  final double start, end, midi, gap, dip;
  final double? midi2, split;
}

PitchTrack _render(List<_Char> chars, double seconds, {double hop = _hop}) {
  final n = (seconds / hop).ceil();
  final midi = Float32List(n), db = Float32List(n)..fillRange(0, n, -100);
  for (var f = 0; f < n; f++) {
    final t = f * hop;
    for (final c in chars) {
      if (t >= c.start - c.gap && t < c.start) db[f] = -45;
      if (t < c.start || t >= c.end) continue;
      var m = c.midi2 != null && t >= c.split! ? c.midi2! : c.midi;
      // A little vibrato on held notes, as singers do.
      if (t - c.start > 0.2) m += 0.3 * math.sin(2 * math.pi * 5.5 * (t - c.start));
      midi[f] = m;
      db[f] = -20 - (t - c.start < 0.05 ? c.dip * (1 - (t - c.start) / 0.05) : 0);
    }
  }
  return PitchTrack(hopSeconds: hop, midi: midi, rmsDb: db, aperiodicity: Float32List(n));
}

List<double> _starts(PitchTrack track, String lyrics) =>
    [for (final t in buildReference(track, parseLrc(lyrics).lines).tokens) t.start];

/// The example of issue #9: “妈妈慢慢来了 / 妈妈”, every character sung,
/// the last one of the first line held twice as long ([tail] seconds).
/// [mode]: `clear` (10 dB dips between the characters and a new pitch for
/// the last one), `weak` (the last one on the same pitch, no dip before
/// it), `faint` (a 2 dB dip there); `turn` adds a 4 semitone step at 3.4 s,
/// inside the held note.
PitchTrack _issueExample(String mode, {double hop = _hop, double tail = 0.8, bool turn = false}) {
  const truth = [1.0, 1.4, 1.8, 2.2, 2.6, 3.0, 6.0, 6.4];
  final n = (9 / hop).ceil();
  final midi = Float32List(n), db = Float32List(n)..fillRange(0, n, -100);
  final pitches = <double>[60, 62, 64, 65, 67, mode == 'clear' ? 69 : 67, 64, 65];
  for (var f = 0; f < n; f++) {
    final t = f * hop;
    for (var k = 0; k < truth.length; k++) {
      final end = k == 5 ? 3.0 + tail : (k == 7 ? 6.8 : truth[k + 1]);
      if (t >= truth[k] && t < end) {
        midi[f] = pitches[k];
        db[f] = -20;
      }
    }
    if (turn && t >= 3.4 && t < 3.0 + tail) midi[f] += 4;
    for (final c in truth.skip(1)) {
      final depth = c != 3.0 || mode == 'clear' ? 10.0 : (mode == 'faint' ? 2.0 : 0.0);
      if (midi[f] > 0 && (t - c).abs() <= 0.05) db[f] -= math.max(0, depth - (t - c).abs() * depth / 0.05);
    }
  }
  return PitchTrack(hopSeconds: hop, midi: midi, rmsDb: db, aperiodicity: Float32List(n));
}

const _issueLyrics = '[00:01.00]妈妈慢慢来了\n[00:06.00]妈妈';
const _issueTruth = [1.0, 1.4, 1.8, 2.2, 2.6, 3.0, 6.0, 6.4];

void main() {
  group('the end of a line (issue #9)', () {
    void expectOthersOnTime(List<double> got) {
      for (var k = 0; k < _issueTruth.length; k++) {
        if (k == 5) continue;
        expect(got[k], closeTo(_issueTruth[k], 0.03), reason: 'character $k');
      }
    }

    for (final hop in [_hop, 0.01]) {
      test('a clear boundary: every character on time (hop ${(hop * 1000).toStringAsFixed(1)} ms)', () {
        for (final turn in [false, true]) {
          final got = _starts(_issueExample('clear', hop: hop, turn: turn), _issueLyrics);
          expectOthersOnTime(got);
          expect(got[5], closeTo(3.0, 0.03), reason: 'turn: $turn');
        }
      });

      test('a held last note does not hand its start to the character before (hop ${(hop * 1000).toStringAsFixed(1)} ms)',
          () {
        // No pitch change and no dip before the last character: only the
        // durations tell. It is held twice as long as the others; it used
        // to start 0.2 s late, where both halves are the usual length.
        final got = _starts(_issueExample('weak', hop: hop), _issueLyrics);
        expectOthersOnTime(got);
        expect(got[5], closeTo(3.0, 0.1));
      });

      test('a turn inside the held note is not taken for sure as its start (hop ${(hop * 1000).toStringAsFixed(1)} ms)',
          () {
        // With nothing (or a 2 dB dip) at 3.0 s and a 4 semitone step at
        // 3.4 s, pitch and level cannot tell the start of the last
        // character from a turn inside it: in real singing a big pitch step
        // and a faint dip each mark a start about as often. The aligner
        // takes the turn; the other characters must stay where they are.
        for (final mode in ['weak', 'faint']) {
          final got = _starts(_issueExample(mode, hop: hop, turn: true), _issueLyrics);
          expectOthersOnTime(got);
          expect(got[5], inInclusiveRange(2.95, 3.45), reason: mode);
        }
      });
    }

    test('the longer the last note is held, the less a weak boundary before it drifts', () {
      // It used to drift to the middle of the last two characters: 0.2 s
      // late for a note held twice as long as the others, 0.6 s for four
      // times as long.
      for (final (tail, within) in [(0.4, 0.03), (0.8, 0.1), (1.2, 0.15), (1.6, 0.2)]) {
        final got = _starts(_issueExample('weak', tail: tail), _issueLyrics);
        expectOthersOnTime(got);
        expect(got[5], closeTo(3.0, within), reason: 'held $tail s');
        final clear = _starts(_issueExample('clear', tail: tail), _issueLyrics);
        expect(clear[5], closeTo(3.0, 0.03), reason: 'clear, held $tail s');
      }
    });
  });

  test('characters sung legato do not push the voiceless ones after them late', () {
    // “草与鸟” on one pitch with nothing between the characters, then
    // “声都是” each after its voiceless consonant. The legato characters
    // used to slide onto the consonant gaps after them, and every
    // character up to the end of the line moved one place late.
    const chars = [
      _Char(1.00, 1.25, 57, gap: 0.09), // 春
      _Char(1.33, 1.60, 59, gap: 0.08), // 天
      _Char(1.60, 1.85, 59), // 里
      _Char(1.85, 2.25, 59, midi2: 61, split: 2.05), // 绿
      _Char(2.34, 2.75, 61, gap: 0.09), // 草
      _Char(2.75, 2.97, 61), // 与
      _Char(2.97, 3.12, 61), // 鸟
      _Char(3.22, 3.40, 60, gap: 0.1), // 声
      _Char(3.47, 3.62, 57, gap: 0.07), // 都
      _Char(3.70, 3.88, 61, gap: 0.08), // 是
      _Char(3.88, 4.36, 66, midi2: 68, split: 4.10), // 明
      _Char(4.36, 4.85, 66), // 亮
    ];
    final got = _starts(_render(chars, 6), '[00:00.90]春天里绿草与鸟声都是明亮');
    for (final k in [0, 1, 4, 7, 8, 9, 10]) {
      expect(got[k], closeTo(chars[k].start, 0.03), reason: 'character $k');
    }
    // Nothing marks where 与 and 鸟 start: they stay inside the held note.
    for (final k in [5, 6]) {
      expect(got[k], inInclusiveRange(chars[4].start, chars[7].start), reason: 'character $k');
    }
  });

  test('a faint level dip marks a character that starts with m, n, l or r', () {
    // “木兰明媚” sung on one pitch, each character after a 1.5 dB dip.
    const chars = [
      _Char(1.0, 1.5, 62, gap: 0.3),
      _Char(1.5, 2.0, 62, dip: 1.5),
      _Char(2.0, 2.5, 62, dip: 1.5),
      _Char(2.5, 3.3, 62, dip: 1.5),
    ];
    final got = _starts(_render(chars, 5), '[00:00.95]木兰明媚');
    for (var k = 0; k < chars.length; k++) {
      expect(got[k], closeTo(chars[k].start, 0.03), reason: 'character $k');
    }
  });

  test('after a breath inside a line any character may start, also one with a vowel', () {
    // A 0.45 s breath before the fourth character, with no space in the
    // lyrics to say so.
    const chars = [
      _Char(1.00, 1.40, 60, gap: 0.1),
      _Char(1.48, 1.90, 62, gap: 0.08),
      _Char(1.98, 2.80, 64, gap: 0.08),
      _Char(3.25, 3.60, 65, gap: 0.45),
      _Char(3.68, 4.00, 64, gap: 0.08),
      _Char(4.08, 4.90, 62, gap: 0.08),
    ];
    for (final lyrics in ['[00:00.90]心底的爱情深', '[00:00.90]心底的看情深']) {
      final got = _starts(_render(chars, 6), lyrics);
      for (var k = 0; k < chars.length; k++) {
        expect(got[k], closeTo(chars[k].start, 0.03), reason: '$lyrics: character $k');
      }
    }
  });
}
