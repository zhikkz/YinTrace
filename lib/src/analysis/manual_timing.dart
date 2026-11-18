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
  return _carryTokenValues(old, lines, (token) => token.pinned);
}

/// Manual readings follow the same occurrences as manual timing.
Map<(int, int), String> carriedPinyin(SongReference old, List<LyricLine> lines) {
  return _carryTokenValues(old, lines, (token) => token.pinyinOverride);
}

Map<(int, int), T> _carryTokenValues<T extends Object>(
  SongReference old,
  List<LyricLine> lines,
  T? Function(RefToken) field,
) {
  if (!old.tokens.any((token) => field(token) != null)) return {};
  final pairs = matchLines(old.lines, [for (final (k, l) in lines.indexed) _standIn(k, l)]);
  return {
    for (final MapEntry(key: k, value: j) in pairs.entries)
      if (_sameWords(lines[j], old.lines[k]))
        for (final (i, token) in old.lines[k].tokens.indexed) (j, i): ?field(token),
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
    // A line the aligner left unsung (evenly spaced, no pitch) is not held:
    // its made-up times could crowd out the line after it.
    final unsung = l.tokens.every((t) => t.notes.isEmpty && t.pinned == null);
    final free = unsung || overlaps(k);
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
  final reference = buildReference(track, lines, language: current.language, pins: all, hold: hold);
  for (final MapEntry(key: (k, i), :value) in carriedPinyin(current, lines).entries) {
    reference.lines[k].tokens[i].pinyinOverride = value;
  }
  return reference;
}

/// Where line [line] can start when only that line is aligned again (with
/// HuBERTFA): the last character of the line before keeps [perToken]
/// seconds and gives up the rest of its sustained tail, as a new alignment
/// of the song cuts between two lines where the second one starts.
double lineStartLimit(SongReference ref, int line, {double perToken = 0.06}) {
  if (line <= 0) return 0;
  final before = ref.lines[line - 1];
  final last = before.tokens.lastOrNull;
  return last == null ? before.end : math.min(before.end, last.start + perToken);
}

/// Where line [line] has to end when only that line is aligned again: where
/// the line after it starts.
double lineEndLimit(SongReference ref, int line) =>
    line + 1 < ref.lines.length ? ref.lines[line + 1].start : ref.duration;

/// Where the start of token [token] of line [line] can be set: between the
/// pins before and after it, and no further than the first character of
/// the line before and the last of the line after (their characters make
/// way), leaving [perToken] seconds to each character in between.
///
/// With [lineOnly] (HuBERTFA aligns only the edited line again) the other
/// lines stay: the range ends at [lineStartLimit] and [lineEndLimit].
(double, double) pinRange(SongReference ref, int line, int token, {double perToken = 0.06, bool lineOnly = false}) {
  if (lineOnly) {
    final tokens = ref.lines[line].tokens;
    var lo = lineStartLimit(ref, line, perToken: perToken) + perToken * token;
    var hi = lineEndLimit(ref, line) - perToken * (tokens.length - token);
    for (var i = token - 1; i >= 0; i--) {
      if (tokens[i].pinned case final pin?) {
        lo = math.max(lo, pin + perToken * (token - i));
        break;
      }
    }
    for (var i = token + 1; i < tokens.length; i++) {
      if (tokens[i].pinned case final pin?) {
        hi = math.min(hi, pin - perToken * (i - token));
        break;
      }
    }
    return (lo, math.max(lo, hi));
  }
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
