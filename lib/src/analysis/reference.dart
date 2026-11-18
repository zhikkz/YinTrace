import 'dart:math' as math;

import 'lyrics_language.dart';

/// A sustained pitch inside a character.
class RefNote {
  RefNote({required this.start, required this.end, required this.midi});

  double start;
  double end;

  /// Median MIDI pitch of the note.
  double midi;

  double get duration => end - start;

  Map<String, dynamic> toJson() => {'s': _r(start), 'e': _r(end), 'm': _r(midi, 100)};

  factory RefNote.fromJson(Map<String, dynamic> j) => RefNote(
      start: (j['s'] as num).toDouble(),
      end: (j['e'] as num).toDouble(),
      midi: (j['m'] as num).toDouble());
}

/// One sung character (or word) with its time span and notes.
///
/// The user can correct a token's pitch: [shift] moves its detected notes
/// (they already include it), [skip] leaves it out of the score, and
/// [manual] marks notes the user added where none were detected. Where the
/// aligner put the token in the wrong place, [pinned] holds the start the
/// user set instead. The detected melody can always be restored.
class RefToken {
  RefToken({
    required this.text,
    required this.start,
    required this.end,
    required this.notes,
    this.spaceBefore = false,
    this.confidence = 1,
    this.shift = 0,
    this.skip = false,
    this.manual = false,
    this.pinned,
    this.pinyinOverride,
  });

  final String text;
  double start;
  double end;
  List<RefNote> notes;

  /// Shown with a space (or a pause) before it.
  final bool spaceBefore;

  /// How sure the aligner was about this token's boundaries (0..1).
  double confidence;

  /// Semitones the user moved the detected notes by.
  double shift;

  /// Not scored (the user says its pitch cannot be trusted).
  bool skip;

  /// The notes were added by the user.
  bool manual;

  /// The start the user set for this token (seconds), or null where the
  /// aligner placed it. Its notes are the voice from there to the next
  /// token, so [start] is where that voice begins.
  double? pinned;

  /// The syllable explicitly chosen for this character (HuBERTFA).
  String? pinyinOverride;

  double get duration => end - start;
  bool get hasPitch => notes.isNotEmpty;

  /// Whether this token counts towards the score.
  bool get scored => !skip && notes.isNotEmpty;

  /// Whether the user changed anything about this token.
  bool get corrected => shift != 0 || skip || manual || pinned != null;

  /// Where the user's or the aligner's slot for this token begins.
  double get slotStart => pinned ?? start;

  /// Moves every note by [semitones].
  void transpose(double semitones) {
    for (final n in notes) {
      n.midi += semitones;
    }
    if (!manual) shift += semitones;
  }

  /// Back to the detected melody. A pinned token also needs aligning again
  /// to go back to where the aligner puts it.
  void restore() {
    if (manual) {
      notes = [];
    } else {
      for (final n in notes) {
        n.midi -= shift;
      }
    }
    shift = 0;
    skip = false;
    manual = false;
    pinned = null;
  }

  /// Copies the corrections of [other] (the same token in an earlier
  /// alignment) onto this one.
  void applyCorrections(RefToken other) {
    if (other.manual) {
      if (notes.isEmpty && other.notes.isNotEmpty) {
        // Over this alignment's span of the token.
        notes = [RefNote(start: start, end: end, midi: other.notes.first.midi)];
        manual = true;
      }
    } else if (other.shift != 0 && notes.isNotEmpty) {
      transpose(other.shift);
    }
    skip = other.skip;
  }

  /// Duration weighted mean pitch (NaN without notes).
  double get meanMidi {
    if (notes.isEmpty) return double.nan;
    var s = 0.0, w = 0.0;
    for (final n in notes) {
      s += n.midi * n.duration;
      w += n.duration;
    }
    return w > 0 ? s / w : notes.first.midi;
  }

  /// Notes are stored as detected; the shift is applied when loading.
  Map<String, dynamic> toJson() => {
        't': text,
        's': _r(start),
        'e': _r(end),
        if (spaceBefore) 'sp': true,
        'c': _r(confidence, 100),
        'n': [
          for (final n in notes) RefNote(start: n.start, end: n.end, midi: n.midi - (manual ? 0 : shift)).toJson()
        ],
        if (shift != 0 && !manual) 'sh': _r(shift, 100),
        if (skip) 'skip': true,
        if (manual) 'man': true,
        if (pinned != null) 'pin': _r(pinned!),
        if (pinyinOverride != null) 'pinyin': pinyinOverride,
      };

  factory RefToken.fromJson(Map<String, dynamic> j) {
    final manual = j['man'] == true;
    final shift = manual ? 0.0 : (j['sh'] as num?)?.toDouble() ?? 0;
    return RefToken(
      text: j['t'] as String,
      start: (j['s'] as num).toDouble(),
      end: (j['e'] as num).toDouble(),
      spaceBefore: j['sp'] == true,
      confidence: (j['c'] as num?)?.toDouble() ?? 1,
      notes: [
        for (final n in j['n'] as List)
          RefNote.fromJson(n as Map<String, dynamic>)..midi += shift,
      ],
      shift: shift,
      skip: j['skip'] == true,
      manual: manual,
      pinned: (j['pin'] as num?)?.toDouble(),
      pinyinOverride: j['pinyin'] as String?,
    );
  }

  /// Whether this token is a Latin word (shown with normal spaces).
  bool get isWord {
    if (text.isEmpty) return false;
    return isLatinLetter(text.runes.first) || (text.runes.first >= 0x30 && text.runes.first <= 0x39);
  }
}

/// Text of a line's tokens as it reads: words separated by spaces, a pause
/// between CJK characters shown as an ideographic space.
String tokenGap(RefToken? previous, RefToken token) {
  if (previous == null || !token.spaceBefore) return '';
  return token.isWord || previous.isWord ? ' ' : '　';
}

class RefLine {
  RefLine({
    required this.index,
    required this.text,
    required this.lrcStart,
    this.lrcEnd,
    required this.tokens,
    this.translation,
  });

  final int index;
  final String text;

  /// The line's translation, when the lyrics came with one: shown under
  /// the line, never sung or scored.
  final String? translation;

  /// Time stamp typed by the user.
  final double lrcStart;
  final double? lrcEnd;
  final List<RefToken> tokens;

  double get start => tokens.isEmpty ? lrcStart : tokens.first.start;
  double get end => tokens.isEmpty ? (lrcEnd ?? lrcStart) : tokens.last.end;

  Iterable<RefNote> get notes => tokens.expand((t) => t.notes);

  /// Notes of the tokens that count towards the score.
  Iterable<RefNote> get scoredNotes => tokens.where((t) => !t.skip).expand((t) => t.notes);

  /// The line's text rebuilt from its tokens (punctuation dropped).
  String get tokenText {
    final b = StringBuffer();
    RefToken? prev;
    for (final t in tokens) {
      b
        ..write(tokenGap(prev, t))
        ..write(t.text);
      prev = t;
    }
    return b.toString();
  }

  Map<String, dynamic> toJson() => {
        'i': index,
        'text': text,
        'ls': _r(lrcStart),
        if (lrcEnd != null) 'le': _r(lrcEnd!),
        if (translation != null) 'tr': translation,
        'tokens': [for (final t in tokens) t.toJson()],
      };

  factory RefLine.fromJson(Map<String, dynamic> j) => RefLine(
        index: (j['i'] as num).toInt(),
        text: j['text'] as String,
        lrcStart: (j['ls'] as num).toDouble(),
        lrcEnd: (j['le'] as num?)?.toDouble(),
        translation: j['tr'] as String?,
        tokens: [for (final t in j['tokens'] as List) RefToken.fromJson(t as Map<String, dynamic>)],
      );
}

/// Everything the practice screen needs to know about the target melody.
class SongReference {
  SongReference({required this.lines, required this.duration, this.language = LyricsLanguage.chinese});

  final List<RefLine> lines;
  final double duration;

  /// The lyrics' language (decides how units are named and laid out).
  final LyricsLanguage language;

  Iterable<RefNote> get notes => lines.expand((l) => l.notes);
  Iterable<RefToken> get tokens => lines.expand((l) => l.tokens);

  /// Pitch range of the melody (MIDI), padded a little.
  (double, double) get pitchRange {
    var lo = double.infinity, hi = -double.infinity;
    for (final n in notes) {
      lo = math.min(lo, n.midi);
      hi = math.max(hi, n.midi);
    }
    if (lo > hi) return (55, 79);
    return (lo, hi);
  }

  /// The line playing at [t] (or the next one), -1 after the last line.
  int lineIndexAt(double t) {
    for (var i = 0; i < lines.length; i++) {
      final next = i + 1 < lines.length ? lines[i + 1].start : double.infinity;
      if (t < next) return i;
    }
    return lines.isEmpty ? -1 : lines.length - 1;
  }

  /// The scored reference note sounding at [t], if any.
  RefNote? noteAt(double t) {
    for (final l in lines) {
      if (t < l.start - 0.5) break;
      if (t > l.end + 0.5) continue;
      for (final n in l.scoredNotes) {
        if (t >= n.start && t < n.end) return n;
      }
    }
    return null;
  }

  /// The first scored note starting after [t] (within [within] seconds).
  RefNote? nextNoteAfter(double t, {double within = 2}) {
    RefNote? best;
    for (final l in lines) {
      if (l.end < t) continue;
      if (l.start > t + within) break;
      for (final n in l.scoredNotes) {
        if (n.start > t && n.start <= t + within && (best == null || n.start < best.start)) best = n;
      }
    }
    return best;
  }

  /// How much of the song the lines with these indices make up, 0..1, by
  /// the time of their scored notes (0 for a song without any).
  double coverageOf(Iterable<int> lineIndices) {
    double seconds(RefLine l) => l.scoredNotes.fold<double>(0, (a, n) => a + n.duration);
    final total = lines.fold<double>(0, (a, l) => a + seconds(l));
    if (total <= 0) return 0;
    var part = 0.0;
    for (final i in lineIndices.toSet()) {
      if (i >= 0 && i < lines.length) part += seconds(lines[i]);
    }
    return (part / total).clamp(0.0, 1.0).toDouble();
  }

  /// Whether any token was corrected by the user.
  bool get corrected => tokens.any((t) => t.corrected);

  /// Copies the user's corrections from [old] (an earlier alignment of the
  /// same song) onto the lines whose words did not change, wherever they
  /// are now: [lineMap] is [matchLines] of the two (computed when omitted).
  void applyCorrectionsFrom(SongReference old, [Map<int, int>? lineMap]) {
    final map = lineMap ?? matchLines(old.lines, lines);
    for (final MapEntry(key: from, value: to) in map.entries) {
      final a = lines[to], b = old.lines[from];
      if (a.tokens.length != b.tokens.length) continue;
      for (var k = 0; k < a.tokens.length; k++) {
        final o = b.tokens[k];
        if (o.corrected && o.text == a.tokens[k].text) a.tokens[k].applyCorrections(o);
      }
    }
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'duration': _r(duration),
        'lang': language.code,
        'lines': [for (final l in lines) l.toJson()],
      };

  factory SongReference.fromJson(Map<String, dynamic> j) => SongReference(
        duration: (j['duration'] as num).toDouble(),
        language: LyricsLanguage.fromCode(j['lang'] as String?),
        lines: [for (final l in j['lines'] as List) RefLine.fromJson(l as Map<String, dynamic>)],
      );
}

/// Pairs the lines of an earlier alignment ([old]) with the lines of a new
/// one ([fresh]) that have the same words: old index -> new index.
///
/// Both lists are in song order, so this is their longest common
/// subsequence: adding, removing or rewriting a line leaves the lines around
/// it paired, wherever they moved to. Where the same words occur several
/// times (a chorus) and not all of them can be paired, the ones closest in
/// time are.
Map<int, int> matchLines(List<RefLine> old, List<RefLine> fresh) {
  String words(RefLine l) => l.tokens.map((t) => t.text).join('\u0001');
  final a = [for (final l in old) words(l)], b = [for (final l in fresh) words(l)];
  final n = a.length, m = b.length;
  // best[i][j]: pairs among old[i..] and fresh[j..], each worth far more
  // than any time difference, minus the seconds the paired lines moved.
  const pair = 1e9;
  final best = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0));
  double paired(int i, int j) => pair - (old[i].lrcStart - fresh[j].lrcStart).abs() + best[i + 1][j + 1];
  for (var i = n - 1; i >= 0; i--) {
    for (var j = m - 1; j >= 0; j--) {
      var v = math.max(best[i + 1][j], best[i][j + 1]);
      if (a[i] == b[j]) v = math.max(v, paired(i, j));
      best[i][j] = v;
    }
  }
  final map = <int, int>{};
  var i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j] && best[i][j] == paired(i, j)) {
      map[i++] = j++;
    } else if (best[i + 1][j] >= best[i][j + 1]) {
      i++;
    } else {
      j++;
    }
  }
  return map;
}

double _r(double v, [int scale = 1000]) => (v * scale).roundToDouble() / scale;
