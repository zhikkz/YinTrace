import 'dart:math' as math;

import 'aligner.dart';
import 'lrc.dart';
import 'pitch_track.dart';
import 'reference.dart';

/// Setting where a character starts by hand, when the aligner got it wrong:
/// the start is pinned, and the rest of its line is aligned again around
/// it, so that the characters after a misplaced one come back too. The
/// other lines stay exactly as they are.

/// The starts the user pinned in [ref], keyed by (line, token).
Map<(int, int), double> pinsOf(SongReference ref) => {
  for (final (k, line) in ref.lines.indexed)
    for (final (i, token) in line.tokens.indexed) (k, i): ?token.pinned,
};

/// The lyric lines [ref] was aligned from, line for line: [lyrics] parsed,
/// each line paired with the reference line of the same words. A reference
/// line without one (a translation line of a song imported before
/// translations were recognised) is rebuilt from the reference itself.
List<LyricLine> linesOfReference(SongReference ref, String lyrics) {
  final parsed = parseLrc(lyrics).lines;
  final pairs = matchLines(ref.lines, [for (final (k, l) in parsed.indexed) _standIn(k, l)]);
  return [
    for (final (k, line) in ref.lines.indexed)
      if (pairs[k] case final j? when _sameWords(parsed[j], line))
        parsed[j]
      else
        LyricLine(
          start: line.lrcStart,
          text: line.text,
          translation: line.translation,
          tokens: [for (final t in line.tokens) LyricToken(t.text, spaceBefore: t.spaceBefore)],
        ),
  ];
}

/// The pins of [old] for [lines], aligned again after the lyrics changed:
/// those of lines whose words did not change, wherever those lines moved.
Map<(int, int), double> carriedPins(SongReference old, List<LyricLine> lines) {
  final pins = pinsOf(old);
  if (pins.isEmpty) return const {};
  final pairs = matchLines(old.lines, [for (final (k, l) in lines.indexed) _standIn(k, l)]);
  return {
    for (final MapEntry(key: (k, i), value: pin) in pins.entries)
      if (pairs[k] case final j? when _sameWords(lines[j], old.lines[k])) (j, i): pin,
  };
}

/// [current] aligned again where only [line] may change, with [pins] (the
/// starts the user set in that line, by token index). Every other line is
/// held where it is, its own pins included, unless a pin overlaps it: a
/// line before whose characters reach past the first pin, or one after
/// that starts before the last, is aligned again too. Corrections are not
/// carried over: apply them from the reference current at that moment
/// ([SongReference.applyCorrectionsFrom]). [lines] are [linesOfReference].
SongReference retimeLine(
  PitchTrack track,
  List<LyricLine> lines,
  SongReference current,
  int line,
  Map<int, double> pins, {
  double perToken = 0.06,
}) {
  final edited = current.lines[line].tokens;
  final firstPin = pins.isEmpty ? null : pins.keys.reduce(math.min);
  final lastPin = pins.isEmpty ? null : pins.keys.reduce(math.max);
  // Room the free characters of the line need before / after its pins.
  final before = firstPin == null ? 0.0 : pins[firstPin]! - perToken * (firstPin + 1);
  final after = lastPin == null ? 0.0 : pins[lastPin]! + perToken * (edited.length - lastPin);
  bool overlaps(int k) {
    if (k == line || pins.isEmpty) return false;
    final tokens = current.lines[k].tokens;
    if (tokens.isEmpty) return false;
    return k < line ? tokens.last.slotStart >= before : tokens.first.slotStart <= after;
  }

  final hold = <(int, int), double>{};
  final all = <(int, int), double>{};
  for (final (k, l) in current.lines.indexed) {
    final free = overlaps(k);
    for (final (i, token) in l.tokens.indexed) {
      if (k == line) {
        if (pins[i] case final pin?) all[(k, i)] = pin;
      } else if (token.pinned case final pin?) {
        all[(k, i)] = pin;
      } else if (!free) {
        hold[(k, i)] = token.start;
      }
    }
  }
  return buildReference(track, lines, language: current.language, pins: all, hold: hold);
}

/// Where the start of token [token] of line [line] can be set: between the
/// pins before and after it, and no further than the first character of
/// the line before and the last of the line after (their characters make
/// way), leaving [perToken] seconds to each character in between.
(double, double) pinRange(SongReference ref, int line, int token, {double perToken = 0.06}) {
  final flat = <(int, int, RefToken)>[
    for (final (k, l) in ref.lines.indexed)
      for (final (i, t) in l.tokens.indexed) (k, i, t),
  ];
  final at = flat.indexWhere((e) => e.$1 == line && e.$2 == token);
  var lo = perToken * at, hi = ref.duration - perToken * (flat.length - 1 - at);
  for (var j = at - 1; j >= 0; j--) {
    final (k, i, t) = flat[j];
    if (t.pinned != null || (k == line - 1 && i == 0) || k < line - 1) {
      lo = math.max(lo, t.slotStart + perToken * (at - j));
      break;
    }
  }
  for (var j = at + 1; j < flat.length; j++) {
    final (k, i, t) = flat[j];
    if (t.pinned != null || (k == line + 1 && i == ref.lines[k].tokens.length - 1) || k > line + 1) {
      hi = math.min(hi, t.slotStart - perToken * (j - at));
      break;
    }
  }
  return (lo, math.max(lo, hi));
}

RefLine _standIn(int k, LyricLine l) => RefLine(
  index: k,
  text: l.text,
  lrcStart: l.start,
  tokens: [for (final t in l.tokens) RefToken(text: t.text, start: l.start, end: l.start, notes: [])],
);

bool _sameWords(LyricLine a, RefLine b) =>
    a.tokens.length == b.tokens.length &&
    [for (var i = 0; i < a.tokens.length; i++) a.tokens[i].text == b.tokens[i].text].every((x) => x);
