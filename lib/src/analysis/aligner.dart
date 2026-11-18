import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import 'lrc.dart';
import 'lyrics_language.dart';
import 'pinyin_initials.dart';
import 'pitch_track.dart';
import 'reference.dart';
import 'reference_notes.dart';

/// Tunables of the character aligner.
class AlignOptions {
  const AlignOptions({
    this.earlySlack = 0.5,
    this.lateSlack = 1.0,
    this.maxLastLine = 12,
    this.gridFrames = 2,
    this.maxTokenSeconds = 4,
    this.noteSplitSemitones = 0.8,
    this.minNoteSeconds = 0.06,
  });

  /// A line may start this much before its time stamp...
  final double earlySlack;

  /// ...or this much after it (time stamps are rarely exact).
  final double lateSlack;

  /// Window for the last line, which has no following time stamp.
  final double maxLastLine;

  /// Boundary resolution in pitch frames.
  final int gridFrames;

  /// Longest sung part of one character.
  final double maxTokenSeconds;
  final double noteSplitSemitones;
  final double minNoteSeconds;
}

/// Builds the per-character reference melody from a pitch track and timed
/// lyrics.
///
/// All characters of the song are placed in one dynamic programme over a
/// ~12 ms grid. Each line's time stamp is a soft anchor for its first
/// character (singers start early or late, and lines often run into each
/// other), boundaries are attracted to syllable onsets whose kind is
/// predicted from how the unit starts (the Mandarin initial, the kana, or
/// the English word's first letters: voiceless consonant gap,
/// voiced-consonant level dip, vowel pitch change), and each unit's voiced
/// duration is kept plausible for its syllables (morae in Japanese); the
/// last one of a line may be held as long as the singer likes. Finally the
/// pitch inside every unit is split into stable notes.
///
/// The weights were checked against sung Mandarin with marked syllable
/// times (GTSinger, two singers, about 5000 characters).
///
/// [language] defaults to the one detected from the lyrics.
///
/// [pins] are starts the user set by hand, keyed by (line, token) index in
/// [lines]: those tokens start exactly there (it is stored as
/// [RefToken.pinned]), the rest of the song is aligned around them, and a
/// line with a pin is aligned even where no voice was found near its time
/// stamp. [hold] keeps tokens where they are in the same way, without
/// storing it (to change one line and leave the others as they are). A pin
/// that cannot be kept (out of order with the others, or with no room for
/// the characters around it) is dropped, and the song is aligned as if it
/// had not been set.
SongReference buildReference(PitchTrack track, List<LyricLine> lines,
    {AlignOptions options = const AlignOptions(),
    LyricsLanguage? language,
    Map<(int, int), double> pins = const {},
    Map<(int, int), double> hold = const {}}) {
  final lang = language ?? detectLyricsLanguage(lines);
  if (lines.isEmpty) return SongReference(lines: const [], duration: track.duration, language: lang);
  final aligner = _ChainAligner(track, options, lang);
  bool valid(MapEntry<(int, int), double> e) =>
      e.key.$1 >= 0 &&
      e.key.$1 < lines.length &&
      e.key.$2 >= 0 &&
      e.key.$2 < lines[e.key.$1].tokens.length &&
      e.value >= 0 &&
      e.value < track.duration;
  final held = {for (final e in hold.entries) if (valid(e)) e.key: e.value};
  final pinned = {for (final e in pins.entries) if (valid(e)) e.key: e.value};
  var (reference, fixed) = _alignFixed(aligner, lines, held, pinned);
  // Word times from the lyrics (enhanced LRC), in lines without fixed
  // starts. The first pass ignores them: a word time marks where the
  // syllable starts, its consonant included, and pulling a character there
  // put it in the end of the voice before. When they agree with where the
  // voice put the characters, each marked character is kept within what
  // its time allows in a second pass, where the voice decides.
  final marks = <(int, int), double>{};
  for (final (k, line) in lines.indexed) {
    if (fixed.keys.any((f) => f.$1 == k)) continue;
    for (final (i, token) in line.tokens.indexed) {
      final time = token.time;
      if (time != null && time >= 0 && time < track.duration) marks[(k, i)] = time;
    }
  }
  final windows = marks.length >= 3 ? _wordTimeWindows(reference, lines, marks, lang) : null;
  if (windows != null) reference = aligner.run(lines, fixed, windows) ?? reference;
  return reference;
}

/// Aligns with the [held] starts and the user's [pins]; a pin that leaves
/// no room goes (the nearest one before where the placement failed), the
/// others stay. Returns the reference and the fixed starts it kept.
(SongReference, Map<(int, int), _Fixed>) _alignFixed(
    _ChainAligner aligner, List<LyricLine> lines, Map<(int, int), double> held, Map<(int, int), double> pinned) {
  if (held.isEmpty && pinned.isEmpty) return (aligner.run(lines, const {})!, const {});
  final left = Map.of(pinned);
  for (;;) {
    final fixed = _ordered(held, left, aligner.cellSeconds);
    final r = aligner.run(lines, fixed);
    if (r != null) return (r, fixed);
    final at = aligner.blocked;
    if (at == null || left.isEmpty) break;
    int order((int, int) k) => k.$1 * 100000 + k.$2;
    final keys = left.keys.toList()..sort((a, b) => order(a) - order(b));
    final before = keys.where((k) => order(k) <= order(at));
    left.remove(before.isNotEmpty ? before.last : keys.first);
  }
  if (held.isNotEmpty) {
    final fixed = _ordered(held, const {}, aligner.cellSeconds);
    final r = aligner.run(lines, fixed);
    if (r != null) return (r, fixed);
  }
  return (aligner.run(lines, const {})!, const {});
}

/// How long after a syllable's marked start its voice begins, by how the
/// syllable starts: typical and longest (median and 98th percentile in sung
/// Mandarin, GTSinger). A voiceless consonant comes first; m/n/l/r and
/// vowels are voiced from the start.
(double, double) _voiceAfterMark(OnsetClass c) => c == OnsetClass.unvoiced ? (0.112, 0.25) : (0.0, 0.15);

/// Where each marked token may start, and where its voice most likely
/// starts, or null when the marks do not agree with [first] (aligned
/// without them): after their common offset, at least 60% of the marked
/// characters must have their voice where their mark says. The offset is
/// found separately for characters with a voiceless initial and the rest,
/// so that word times off by a constant, or put where the voice starts
/// rather than the syllable, fit too; ones that do not fit the voice are
/// not used.
Map<(int, int), (double, double, double)>? _wordTimeWindows(
    SongReference first, List<LyricLine> lines, Map<(int, int), double> marks, LyricsLanguage language) {
  final classes = {for (final k in marks.keys) k: tokenOnsetClass(lines[k.$1].tokens[k.$2], language)};
  bool voiceless((int, int) k) => classes[k] == OnsetClass.unvoiced;
  final d = <(int, int), double>{};
  for (final MapEntry(key: k, value: time) in marks.entries) {
    if (k.$1 >= first.lines.length || k.$2 >= first.lines[k.$1].tokens.length) continue;
    final token = first.lines[k.$1].tokens[k.$2];
    if (token.notes.isEmpty) continue;
    d[k] = token.start - time - _voiceAfterMark(classes[k]!).$1;
  }
  if (d.length < 3) return null;
  final all = median(d.values.toList());
  double offsetOf(bool unvoiced) {
    final own = [for (final e in d.entries) if (voiceless(e.key) == unvoiced) e.value];
    return own.length >= 3 ? median(own) : all;
  }

  // One offset for all, unless the two kinds clearly differ (word times
  // put where the voice starts: a voiceless initial's mark is late by its
  // consonant).
  final split = (offsetOf(true) - offsetOf(false)).abs() > 0.06;
  final offsets = {true: split ? offsetOf(true) : all, false: split ? offsetOf(false) : all};
  final agree = d.entries.where((e) => (e.value - offsets[voiceless(e.key)]!).abs() <= 0.12).length / d.length;
  if (agree < 0.6 || offsets.values.any((o) => o.abs() > 1.0)) return null;
  return {
    for (final MapEntry(key: k, value: time) in marks.entries)
      k: (
        time + offsets[voiceless(k)]! - 0.08,
        time + offsets[voiceless(k)]! + _voiceAfterMark(classes[k]!).$2 + 0.08,
        time + offsets[voiceless(k)]! + _voiceAfterMark(classes[k]!).$1,
      ),
  };
}

/// The fixed starts in song order, each at least two grid cells after the
/// one before; a user pin that breaks the order gives way to a held start.
Map<(int, int), _Fixed> _ordered(Map<(int, int), double> held, Map<(int, int), double> pins, double cell) {
  final all = <(int, int), _Fixed>{
    for (final e in held.entries) e.key: _Fixed(e.value, user: false),
    for (final e in pins.entries) e.key: _Fixed(e.value, user: true),
  };
  final keys = all.keys.toList()..sort((a, b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2);
  final out = <(int, int), _Fixed>{};
  (int, int)? last;
  for (final k in keys) {
    final f = all[k]!;
    final before = last == null ? null : out[last]!;
    if (before == null || f.seconds >= before.seconds + 2 * cell) {
      out[k] = f;
      last = k;
    } else if (!f.user && before.user) {
      // A held start wins over a pin it conflicts with.
      out.remove(last);
      out[k] = f;
      last = k;
    }
  }
  return out;
}

/// A start kept fixed: set by the user ([user]) or held from before.
class _Fixed {
  const _Fixed(this.seconds, {required this.user});
  final double seconds;
  final bool user;
}

/// One syllable placed by the dynamic programme. A token is one or more
/// consecutive units (an English word: one per syllable).
class _Tok {
  _Tok(this.line, this.index, this.token, this.cls, this.weight, this.first, this.last,
      {required this.lead, this.lineStop, this.fixed});
  final int line;

  /// Index of the token in its line.
  final int index;
  final LyricToken token;
  final OnsetClass cls;

  /// Expected length in syllables (morae).
  final double weight;

  /// First / last unit of its line.
  final bool first;
  final bool last;

  /// First unit of its token (where a pause applies).
  final bool lead;

  /// When the next line starts, or this one is marked to end; null for the
  /// last line without an end mark.
  final double? lineStop;

  /// Where this unit must start (only a token's first unit).
  final _Fixed? fixed;

  /// Where its word time says its voice starts.
  double? expected;
  int lo = 0; // grid range [lo, hi)
  int lineHi = 0; // end of its line's window
  int hi = 0;
  late Float64List dp;
  late Int32List back;
}

class _ChainAligner {
  _ChainAligner(this.t, this.o, this.language)
      : hop = t.hopSeconds,
        g = math.max(1, o.gridFrames) {
    final n = t.length;
    _voicedPrefix = Int32List(n + 1);
    for (var i = 0; i < n; i++) {
      _voicedPrefix[i + 1] = _voicedPrefix[i] + (t.voiced(i) ? 1 : 0);
    }
    _energy = _smooth(t.rmsDb, 2);
    // _nextBreak[f]: first frame >= f inside a silence of at least
    // [_breakSeconds]; voicing after it does not belong to the same phrase.
    final minBreak = (_breakSeconds / hop).round();
    final unvRun = Int32List(n + 1);
    for (var i = n - 1; i >= 0; i--) {
      unvRun[i] = t.voiced(i) ? 0 : unvRun[i + 1] + 1;
    }
    _nextBreak = Int32List(n + 1)..[n] = n;
    for (var i = n - 1; i >= 0; i--) {
      _nextBreak[i] = unvRun[i] >= minBreak ? i : _nextBreak[i + 1];
    }
    // A character may start on the consonant just before the voice (up to
    // 0.25 s): look past that lead-in before deciding it sits in silence.
    final lead = (0.25 / hop).round();
    for (var i = 0; i < n; i++) {
      if (_nextBreak[i] == i && unvRun[i] <= lead && i + unvRun[i] < n) {
        _nextBreak[i] = _nextBreak[i + unvRun[i]];
      }
    }
    // Most recent voiced onset (after >= 2 unvoiced frames) at or before f.
    _lastOnset = Int32List(n);
    var last = -1000000;
    for (var i = 0; i < n; i++) {
      if (t.voiced(i) && i >= 2 && !t.voiced(i - 1) && !t.voiced(i - 2)) last = i;
      _lastOnset[i] = last;
    }
    _cells = (n + g - 1) ~/ g;
    _gap = Float64List(_cells);
    _dip = Float64List(_cells);
    _jump = Float64List(_cells);
    _voicedAt = List<bool>.filled(_cells, false);
    for (var c = 0; c < _cells; c++) {
      for (var j = c * g; j < math.min(n, c * g + g); j++) {
        _gap[c] = math.max(_gap[c], _gapBefore(j));
        _dip[c] = math.max(_dip[c], _dipAt(j));
        _jump[c] = math.max(_jump[c], _jumpAt(j));
        if (t.voiced(j)) _voicedAt[c] = true;
      }
    }
    // How much the sound changes at each cell, against how much it
    // usually does in this song's singing (reverb and the voice itself
    // move the whole scale).
    final change = t.spectralChange;
    final usual = change == null ? <double>[] : [for (var i = 0; i < n; i++) if (t.voiced(i)) change[i]];
    if (change != null && usual.length >= 10) {
      _usualChange = median(usual);
      final cells = Float64List(_cells);
      for (var c = 0; c < _cells; c++) {
        for (var j = math.max(0, c * g - 2); j <= math.min(n - 1, c * g + 2); j++) {
          cells[c] = math.max(cells[c], change[j]);
        }
      }
      if (_usualChange > 0) _change = cells;
    }
  }

  final PitchTrack t;
  final AlignOptions o;
  final LyricsLanguage language;
  final double hop;
  final int g;
  late final Int32List _voicedPrefix;
  late final Int32List _nextBreak;
  late final Int32List _lastOnset;
  static const _breakSeconds = 0.6;
  late final Float32List _energy;
  late final int _cells;
  late final Float64List _gap; // seconds of voicelessness right before
  late final Float64List _dip; // dB depth of a level dip
  late final Float64List _jump; // semitones of pitch change
  late final List<bool> _voicedAt;
  Float64List? _change; // spectral change, when the track has it
  double _usualChange = 0;

  static Float32List _smooth(Float32List x, int r) {
    final out = Float32List(x.length);
    for (var i = 0; i < x.length; i++) {
      var s = 0.0;
      var c = 0;
      for (var k = math.max(0, i - r); k < math.min(x.length, i + r + 1); k++) {
        s += x[k];
        c++;
      }
      out[i] = s / c;
    }
    return out;
  }

  int frameOf(double s) => (s / hop).round().clamp(0, t.length).toInt();
  int cellOf(double s) => (frameOf(s) / g).floor().clamp(0, _cells).toInt();
  double secOfCell(int c) => c * g * hop;
  double get cellSeconds => g * hop;

  /// Points a start loses per second away from where its word time says.
  static const _wordPull = 10.0;

  /// Where the last [run] found no placement: the (line, token) of the
  /// fixed start it could not keep.
  (int, int)? blocked;

  /// Seconds of unvoiced signal right before a voiced frame [j].
  double _gapBefore(int j) {
    final voicedHere = t.voiced(j) || (j + 1 < t.length && t.voiced(j + 1));
    if (!voicedHere) return 0;
    var k = 0;
    while (j - 1 - k >= 0 && !t.voiced(j - 1 - k) && k < 200) {
      k++;
    }
    return k >= 2 ? k * hop : 0;
  }

  double _dipAt(int j) {
    if (!t.voiced(j)) return 0;
    final n = t.length;
    for (var k = math.max(0, j - 3); k <= math.min(n - 1, j + 3); k++) {
      if (_energy[k] < _energy[j] - 0.01) return 0;
    }
    var leftMax = -1e9, rightMax = -1e9;
    for (var k = math.max(0, j - 8); k < j; k++) {
      leftMax = math.max(leftMax, _energy[k]);
    }
    for (var k = j + 1; k <= math.min(n - 1, j + 8); k++) {
      rightMax = math.max(rightMax, _energy[k]);
    }
    final d = math.min(leftMax, rightMax) - _energy[j];
    return d > 0 ? d : 0;
  }

  double _jumpAt(int j) {
    final left = <double>[], right = <double>[];
    for (var k = math.max(0, j - 8); k < j; k++) {
      if (t.voiced(k)) left.add(t.midi[k]);
    }
    for (var k = j; k < math.min(t.length, j + 8); k++) {
      if (t.voiced(k)) right.add(t.midi[k]);
    }
    if (left.length < 3 || right.length < 3) return 0;
    final d = (median(right) - median(left)).abs();
    // Singers slide ("scoop") into a note right after its onset; such a
    // pitch change is not a new syllable.
    if (j - _lastOnset[j] < (0.15 / hop).round()) return d * 0.25;
    return d;
  }

  /// Evidence that [tok] starts at grid cell [c].
  double _onset(_Tok tok, int c) {
    final gap = _gap[c];
    final dip = math.min(_dip[c], 12.0);
    final jump = math.min(_jump[c], 4.0);
    double s;
    final gapScore = gap > 0 ? 2.0 + math.min(gap, 0.25) / 0.05 : 0.0;
    final pause = tok.lead && tok.token.pauseBefore;
    // Inside a line, a short voiceless gap marks a voiceless consonant. In
    // sung Mandarin one comes before nearly every character that starts
    // with one, but before few that start with m/n/l/r or a vowel. Those
    // get less for a gap, or they slide onto the gap of a voiceless
    // character after them and shift the rest of the line. A longer gap is
    // a breath, after which any character may start.
    final consonantGap = !tok.first && !pause && gap > 0 && gap < 0.2;
    final legatoGap = consonantGap ? gapScore * 0.7 : gapScore;
    switch (tok.cls) {
      case OnsetClass.unvoiced:
        // A gap is expected, but unaspirated b/d/g/j/zh/z and h are often
        // voiced when sung: then a dip or a pitch change marks the onset.
        s = gapScore > 0 ? gapScore * 1.2 : (dip >= 1 ? dip / 3 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.voiced:
        s = math.max(legatoGap, dip >= 1 ? dip / 3 * 1.4 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.vowel:
        s = math.max(legatoGap, dip >= 1 ? dip / 3 : 0);
        s += 0.7 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.unknown:
        s = math.max(gapScore, dip >= 1 ? dip / 3 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
    }
    if (!_voicedAt[c] && gap == 0) s -= 2; // starts must be on the voice
    final change = _change;
    if (change != null && gap == 0 && _voicedAt[c]) {
      // Sung legato, a new character still changes the sound (the vowel, a
      // consonant, often the note); the middle of a held note does not. In
      // sung Mandarin most such starts change it by well over the usual
      // amount, few places inside a character do, and a start where
      // nothing changes counts against it. A turn inside a character
      // changes it too, but mostly less: of a character boundary with a
      // change of note and a note change inside a character, the boundary
      // changes the sound more three times in four.
      s += ((change[c] - 1.8 * _usualChange) / (0.8 * _usualChange)).clamp(-1.0, 1.0);
    }
    if (pause) s = gap > 0 ? s * 1.5 + 1 : s - 1;
    if (!tok.first) {
      // Long silences rarely happen inside a line (a little longer at a
      // pause): a character after one most likely starts the next line.
      final allowed = pause ? 1.2 : (tok.lead ? 0.6 : 0.4);
      if (gap > allowed) s -= math.min(8.0, (gap - allowed) * 10);
    }
    // A character rarely starts once the next line is due. Without this a
    // line can slide a character late, its last character taking the first
    // onset of the next line.
    // A word time that agrees with the voice: where nothing else tells,
    // near it rather than far.
    final expected = tok.expected;
    if (expected != null) s -= (secOfCell(c) - expected).abs() * _wordPull;
    final stop = tok.lineStop;
    if (stop != null) {
      final over = secOfCell(c) - (stop - 0.1);
      if (over > 0) s -= 10 * over;
    }
    return s;
  }

  /// Penalty for a line's first character starting at [t] given its
  /// time stamp [stamp].
  static double _anchor(double t, double stamp) {
    final d = t - stamp;
    if (d < -0.15) return 10 * (-0.15 - d);
    if (d > 0.35) return 8 * (d - 0.35);
    return 0;
  }

  /// The reference, or null when the [fixed] starts (or the [windows] some
  /// tokens must start in) leave no placement.
  SongReference? run(List<LyricLine> lines, Map<(int, int), _Fixed> fixed,
      [Map<(int, int), (double, double, double)> windows = const {}]) {
    blocked = null;
    final constrained = fixed.isNotEmpty || windows.isNotEmpty;
    final toks = <_Tok>[];
    final lineAvg = <double>[];
    final end = t.duration;
    // Lines with no voice anywhere near their time stamp are not sung by
    // the lead vocal (e.g. backing-vocal only); keep them out of the joint
    // alignment so they cannot steal syllables from their neighbours.
    final sung = List<bool>.filled(lines.length, false);
    for (var k = 0; k < lines.length; k++) {
      final line = lines[k];
      final next = k + 1 < lines.length ? lines[k + 1].start : math.min(end, line.start + o.maxLastLine);
      var stop = line.end ?? next;
      if (stop > next) stop = next;
      var lo = cellOf(math.max(0, line.start - o.earlySlack));
      final firstEnd = math.min(end, math.min(line.start + o.lateSlack, stop));
      final f0 = math.min(lo * g, t.length), f1 = frameOf(firstEnd);
      sung[k] = f1 > f0 && _voicedPrefix[f1] - _voicedPrefix[f0] >= (0.08 / hop).round();
      final n = line.tokens.length;
      final syllables = [for (final tok in line.tokens) tokenSyllables(tok, language)];
      final units = syllables.fold<double>(0, (a, s) => a + s.fold<double>(0, (b, x) => b + x.$2));
      // A line cannot plausibly last much longer than ~1 s per syllable.
      final cap = line.start + 1.5 + units * 1.0;
      var hi = math.max(lo + 1, cellOf(math.min(end, math.min(stop + o.lateSlack, cap))));
      var firstHi = math.max(lo + 1, math.min(hi, cellOf(line.start + o.lateSlack) + 1));
      // Fixed starts in this line: the user knows better than the time
      // stamp, so the line gets room around them.
      final fixedHere = [for (var i = 0; i < n; i++) if (fixed[(k, i)] != null) i];
      var pinnedLate = false;
      if (fixedHere.isNotEmpty) {
        if (fixedHere.any((i) => fixed[(k, i)]!.user)) sung[k] = true;
        var unitsBefore = 0;
        for (var i = 0; i < fixedHere.first; i++) {
          unitsBefore += syllables[i].length;
        }
        var unitsAfter = 0;
        for (var i = fixedHere.last; i < n; i++) {
          unitsAfter += syllables[i].length;
        }
        final c1 = cellOf(fixed[(k, fixedHere.first)]!.seconds), c2 = cellOf(fixed[(k, fixedHere.last)]!.seconds);
        lo = math.min(lo, math.max(0, c1 - unitsBefore * cellOf(0.6) - 1));
        hi = math.min(_cells, math.max(hi, c2 + unitsAfter * cellOf(1.0) + 1));
        if (fixedHere.first > 0) firstHi = math.max(firstHi, c1 - unitsBefore + 1);
        firstHi = math.min(firstHi, hi);
        pinnedLate = fixedHere.any((i) => fixed[(k, i)]!.user && fixed[(k, i)]!.seconds > stop - 0.1);
      }
      // Expected voiced seconds per syllable in this line. Its last syllable
      // is usually held, about as long as two: counted so, it does not make
      // every other character of the line expected longer.
      final v0 = frameOf(math.max(0, line.start - 0.2)), v1 = frameOf(math.min(end, stop + 0.3));
      final voiced = (_voicedPrefix[v1] - _voicedPrefix[v0]) * hop;
      lineAvg.add((voiced / (units + 1)).clamp(0.12, 1.5).toDouble());
      if (!sung[k]) continue;
      // A pin after the next line's time stamp says the stamp is wrong.
      final lineStop = (k + 1 < lines.length || line.end != null) && !pinnedLate ? stop : null;
      for (var i = 0; i < n; i++) {
        final syl = syllables[i];
        for (var j = 0; j < syl.length; j++) {
          final f = j == 0 ? fixed[(k, i)] : null;
          final tok = _Tok(k, i, line.tokens[i], syl[j].$1, syl[j].$2, i == 0 && j == 0,
              i == n - 1 && j == syl.length - 1, lead: j == 0, lineStop: lineStop, fixed: f)
            ..lo = lo
            ..hi = i == 0 && j == 0 ? firstHi : hi
            ..lineHi = hi;
          if (f != null) {
            tok.lo = cellOf(f.seconds);
            tok.hi = tok.lo + 1;
          } else if (windows[(k, i)] case final w? when j == 0) {
            // A window with voice in it, inside the line's range.
            final a = math.max(tok.lo, cellOf(w.$1)), b = math.min(tok.hi, cellOf(w.$2) + 1);
            var voiced = false;
            for (var c = a; c < b && !voiced; c++) {
              voiced = _voicedAt[c];
            }
            if (voiced) {
              tok.lo = a;
              tok.hi = b;
              tok.expected = w.$3;
            }
          }
          toks.add(tok);
        }
      }
    }
    if (toks.isEmpty) {
      return SongReference(
          lines: [for (var k = 0; k < lines.length; k++) _unsungLine(k, lines)],
          duration: t.duration,
          language: language);
    }
    // Keep the ranges feasible for a strictly increasing placement. A fixed
    // start is never moved: with no room around it, there is no placement.
    for (var m = 1; m < toks.length; m++) {
      final need = toks[m - 1].lo + 1;
      if (toks[m].fixed != null) {
        if (need > toks[m].lo) {
          blocked = (toks[m].line, toks[m].index);
          return null;
        }
      } else {
        toks[m].lo = math.max(toks[m].lo, need);
      }
    }
    for (var m = toks.length - 1; m >= 0; m--) {
      final cap = m + 1 < toks.length ? toks[m + 1].hi - 1 : _cells;
      if (toks[m].fixed != null) {
        if (toks[m].hi > cap) {
          blocked = (toks[m].line, toks[m].index);
          return null;
        }
      } else {
        toks[m].hi = math.max(toks[m].lo + 1, math.min(toks[m].hi, cap));
      }
    }

    // Duration penalty tables per line and token length, indexed by voiced
    // frames. A token of several syllables (an English word, a kanji read
    // with several morae) is expected to last that much longer.
    var maxWeight = 1.0;
    for (final tok in toks) {
      maxWeight = math.max(maxWeight, tok.weight);
    }
    double maxSeconds(double weight) => o.maxTokenSeconds * math.max(1.0, weight / 2);
    final maxRaw = ((maxSeconds(maxWeight) * 1.25) / hop / g).ceil();
    // A slot with almost no voice is very unlikely; a short one (a quick or
    // breathy syllable) only a little: rather that than moving every
    // following character onto its neighbour's voice.
    double penalty(double dv, double avg, double weight, bool last) {
      var p = 0.0;
      if (dv < 0.04) {
        p += 25;
      } else if (dv < 0.08) {
        p += 1;
      }
      final max = maxSeconds(weight);
      if (dv > max) p += 10 + (dv - max) * 5;
      final l = math.log(math.max(dv, 0.02) / (avg * weight));
      // The last syllable of a line may be held as long as the singer
      // likes: only being too short counts against it. Otherwise a weak
      // boundary before a long final note moves to where both halves are
      // the usual length, and the character before takes the start of it.
      if (last && l > 0) return p;
      return p + 0.35 * l * l;
    }

    final penTables = <int, Float64List>{};
    Float64List penTable(_Tok tok) {
      final key = (tok.line * 64 + (tok.weight * 4).round().clamp(0, 63)) * 2 + (tok.last ? 1 : 0);
      return penTables.putIfAbsent(key, () {
        final size = maxRaw * g + 1;
        final tab = Float64List(size);
        for (var v = 0; v < size; v++) {
          tab[v] = penalty(v * hop, lineAvg[tok.line], tok.weight, tok.last);
        }
        return tab;
      });
    }

    // Voiced frames of a slot that belong to the same phrase as its start.
    int connectedVoiced(int a, int b) => _voicedPrefix[math.min(b, _nextBreak[a])] - _voicedPrefix[a];
    double voicedPen(_Tok tok, int fromCell, int toCell) {
      final a = math.min(fromCell * g, t.length), b = math.min(toCell * g, t.length);
      final v = connectedVoiced(a, b);
      final tab = penTable(tok);
      if (v < tab.length) return tab[v];
      return penalty(v * hop, lineAvg[tok.line], tok.weight, tok.last);
    }

    const neg = -1e18;
    for (final tok in toks) {
      final len = tok.hi - tok.lo;
      tok.dp = Float64List(len)..fillRange(0, len, neg);
      tok.back = Int32List(len)..fillRange(0, len, -1);
    }
    final first = toks.first;
    for (var c = first.lo; c < first.hi; c++) {
      first.dp[c - first.lo] = _onset(first, c) - _anchor(secOfCell(c), lines[first.line].start);
    }
    for (var m = 1; m < toks.length; m++) {
      final prev = toks[m - 1], cur = toks[m];
      final crossLine = cur.first;
      final stamp = lines[cur.line].start;
      final tab = penTable(prev);
      for (var c = cur.lo; c < cur.hi; c++) {
        final iHi = math.min(prev.hi, c);
        final iLo = crossLine ? prev.lo : math.max(prev.lo, c - maxRaw);
        if (iHi <= iLo) continue;
        var best = neg;
        var arg = -1;
        final fc = math.min(c * g, t.length);
        for (var i = iLo; i < iHi; i++) {
          final pv = prev.dp[i - prev.lo];
          if (pv <= neg / 2) continue;
          final fi = math.min(i * g, t.length);
          final v = _voicedPrefix[math.min(fc, _nextBreak[fi])] - _voicedPrefix[fi];
          final pen = v < tab.length ? tab[v] : voicedPen(prev, i, c);
          var val = pv - pen;
          if (!crossLine && c - i > maxRaw) val -= 50;
          if (val > best) {
            best = val;
            arg = i;
          }
        }
        if (arg < 0) continue;
        var s = _onset(cur, c);
        if (crossLine) s -= _anchor(secOfCell(c), stamp);
        cur.dp[c - cur.lo] = best + s;
        cur.back[c - cur.lo] = arg;
      }
      if (constrained && !cur.dp.any((v) => v > neg / 2)) {
        // No way to reach this unit: blame the fixed start that hems it in.
        var f = m;
        while (f < toks.length && toks[f].fixed == null) {
          f++;
        }
        if (f == toks.length) f = m;
        blocked = (toks[f].line, toks[f].index);
        return null;
      }
    }
    // Close the last character at the end of its window.
    final last = toks.last;
    // A fixed last character still runs to the end of its line's window.
    final endCell = last.fixed == null ? last.hi : math.max(last.hi, math.min(last.lineHi, _cells));
    var best = neg;
    var arg = -1;
    for (var c = last.lo; c < last.hi; c++) {
      final pv = last.dp[c - last.lo];
      if (pv <= neg / 2) continue;
      final v = pv - voicedPen(last, c, endCell);
      if (v > best) {
        best = v;
        arg = c;
      }
    }
    final starts = List<int>.filled(toks.length, 0);
    if (arg < 0 && constrained) {
      final f = toks.lastIndexWhere((t) => t.fixed != null);
      blocked = f < 0 ? null : (toks[f].line, toks[f].index);
      return null;
    }
    if (arg < 0) {
      // Infeasible (should not happen): fall back to the time stamps.
      for (var m = 0; m < toks.length; m++) {
        starts[m] = toks[m].lo;
      }
    } else {
      starts[toks.length - 1] = arg;
      for (var m = toks.length - 1; m > 0; m--) {
        final b = toks[m].back[starts[m] - toks[m].lo];
        starts[m - 1] = b >= 0 ? b : math.max(toks[m - 1].lo, starts[m] - 1);
      }
    }

    // Build the reference. A fixed start is used to the frame.
    int frameStart(int x) {
      final f = toks[x].fixed;
      return f == null ? starts[x] * g : frameOf(f.seconds);
    }

    final out = <RefLine>[];
    var m = 0;
    for (var k = 0; k < lines.length; k++) {
      if (!sung[k]) {
        out.add(_unsungLine(k, lines));
        continue;
      }
      final line = lines[k];
      final refTokens = <RefToken>[];
      for (var i = 0; i < line.tokens.length; i++) {
        // The token's units: m (its first syllable) up to the next token.
        final first = m;
        while (m + 1 < toks.length && toks[m + 1].line == k && toks[m + 1].index == i) {
          m++;
        }
        m++;
        final s = frameStart(first);
        final e = m < toks.length ? frameStart(m) : endCell * g;
        // A character the user placed takes the voice anywhere in its slot,
        // however long the consonant or the silence before it.
        final pin = toks[first].fixed;
        final user = pin != null && pin.user;
        final (vs, ve) = _voicedExtent(s, math.max(s + 1, e), anyLead: user);
        final notes = notesInFrames(
          t, vs, ve, splitSemitones: o.noteSplitSemitones, minNoteSeconds: o.minNoteSeconds,
        );
        final onset = _onset(toks[first], starts[first]);
        refTokens.add(RefToken(
          text: line.tokens[i].text,
          start: vs * hop,
          end: ve > vs ? ve * hop : (s + (0.25 / hop).round()) * hop,
          notes: notes,
          spaceBefore: line.tokens[i].spaceBefore,
          confidence: notes.isEmpty ? 0 : (0.4 + onset / 6).clamp(0.0, 1.0).toDouble(),
          pinned: user ? pin.seconds : null,
        ));
      }
      out.add(RefLine(
        index: k,
        text: line.text,
        lrcStart: line.start,
        lrcEnd: k + 1 < lines.length ? lines[k + 1].start : null,
        translation: line.translation,
        tokens: refTokens,
      ));
    }
    return SongReference(lines: out, duration: t.duration, language: language);
  }

  /// A line the lead vocal does not sing: evenly spaced, pitchless tokens.
  RefLine _unsungLine(int k, List<LyricLine> lines) {
    final line = lines[k];
    final n = line.tokens.length;
    final next = k + 1 < lines.length ? lines[k + 1].start : line.start + 0.35 * n;
    final span = math.max(0.2 * n, math.min(next - line.start, 0.35 * n));
    final step = span / n;
    return RefLine(
      index: k,
      text: line.text,
      lrcStart: line.start,
      lrcEnd: k + 1 < lines.length ? lines[k + 1].start : null,
      translation: line.translation,
      tokens: [
        for (var i = 0; i < n; i++)
          RefToken(
            text: line.tokens[i].text,
            start: line.start + i * step,
            end: line.start + (i + 1) * step,
            notes: [],
            spaceBefore: line.tokens[i].spaceBefore,
            confidence: 0,
          )
      ],
    );
  }

  /// The voiced part of a slot: from its first voiced frame (allowing for
  /// the consonant) through the voiced runs connected to it.
  (int, int) _voicedExtent(int s, int e, {bool anyLead = false}) {
    final n = t.length;
    e = math.min(e, n);
    var a = s;
    final maxLead = anyLead ? e - s : (0.25 / hop).round();
    while (a < e && a - s < maxLead && !t.voiced(a)) {
      a++;
    }
    if (a >= e || !t.voiced(a)) return (s, s);
    final maxGap = (0.25 / hop).round();
    var b = a;
    var i = a;
    while (i < e) {
      if (t.voiced(i)) {
        b = i + 1;
        i++;
        continue;
      }
      var j = i;
      while (j < e && !t.voiced(j)) {
        j++;
      }
      if (j >= e || j - i > maxGap) break;
      i = j;
    }
    return (a, b);
  }
}
