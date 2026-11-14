import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import 'lrc.dart';
import 'lyrics_language.dart';
import 'pinyin_initials.dart';
import 'pitch_track.dart';
import 'reference.dart';

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
/// duration is kept plausible for its syllables (morae in Japanese).
/// Finally the pitch inside every unit is split into stable notes.
///
/// [language] defaults to the one detected from the lyrics.
SongReference buildReference(PitchTrack track, List<LyricLine> lines,
    {AlignOptions options = const AlignOptions(), LyricsLanguage? language}) {
  final lang = language ?? detectLyricsLanguage(lines);
  if (lines.isEmpty) return SongReference(lines: const [], duration: track.duration, language: lang);
  return _ChainAligner(track, options, lang).run(lines);
}

/// One syllable placed by the dynamic programme. A token is one or more
/// consecutive units (an English word: one per syllable).
class _Tok {
  _Tok(this.line, this.index, this.token, this.cls, this.weight, this.first, this.last, {required this.lead});
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

  /// First unit of its token (where a pause or a word time applies).
  final bool lead;
  int lo = 0; // grid range [lo, hi)
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
    switch (tok.cls) {
      case OnsetClass.unvoiced:
        // A gap is expected, but unaspirated b/d/g/j/zh/z and h are often
        // voiced when sung: then a dip or a pitch change marks the onset.
        s = gapScore > 0 ? gapScore * 1.2 : (dip >= 2 ? dip / 3 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.voiced:
        s = math.max(gapScore, dip >= 2 ? dip / 3 * 1.4 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.vowel:
        s = math.max(gapScore, dip >= 2 ? dip / 3 : 0);
        s += 0.7 * (jump >= 0.7 ? jump : 0);
      case OnsetClass.unknown:
        s = math.max(gapScore, dip >= 2 ? dip / 3 : 0);
        s += 0.6 * (jump >= 0.7 ? jump : 0);
    }
    if (!_voicedAt[c] && gap == 0) s -= 2; // starts must be on the voice
    final pause = tok.lead && tok.token.pauseBefore;
    if (pause) s = gap > 0 ? s * 1.5 + 1 : s - 1;
    if (!tok.first) {
      // Long silences rarely happen inside a line (a little longer at a
      // pause): a character after one most likely starts the next line.
      final allowed = pause ? 1.2 : (tok.lead ? 0.6 : 0.4);
      if (gap > allowed) s -= math.min(8.0, (gap - allowed) * 10);
    }
    final time = tok.lead ? tok.token.time : null;
    if (time != null && (secOfCell(c) - time).abs() < 0.08) s += 10;
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

  SongReference run(List<LyricLine> lines) {
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
      final lo = cellOf(math.max(0, line.start - o.earlySlack));
      final firstEnd = math.min(end, math.min(line.start + o.lateSlack, stop));
      final f0 = math.min(lo * g, t.length), f1 = frameOf(firstEnd);
      sung[k] = f1 > f0 && _voicedPrefix[f1] - _voicedPrefix[f0] >= (0.08 / hop).round();
      final n = line.tokens.length;
      final syllables = [for (final tok in line.tokens) tokenSyllables(tok, language)];
      final units = syllables.fold<double>(0, (a, s) => a + s.fold<double>(0, (b, x) => b + x.$2));
      // A line cannot plausibly last much longer than ~1 s per syllable.
      final cap = line.start + 1.5 + units * 1.0;
      final hi = math.max(lo + 1, cellOf(math.min(end, math.min(stop + o.lateSlack, cap))));
      final firstHi = math.max(lo + 1, math.min(hi, cellOf(line.start + o.lateSlack) + 1));
      // Expected voiced seconds per syllable in this line.
      final v0 = frameOf(math.max(0, line.start - 0.2)), v1 = frameOf(math.min(end, stop + 0.3));
      final voiced = (_voicedPrefix[v1] - _voicedPrefix[v0]) * hop;
      lineAvg.add((voiced / units).clamp(0.12, 1.5).toDouble());
      if (!sung[k]) continue;
      for (var i = 0; i < n; i++) {
        final syl = syllables[i];
        for (var j = 0; j < syl.length; j++) {
          final tok = _Tok(k, i, line.tokens[i], syl[j].$1, syl[j].$2, i == 0 && j == 0,
              i == n - 1 && j == syl.length - 1, lead: j == 0)
            ..lo = lo
            ..hi = i == 0 && j == 0 ? firstHi : hi;
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
    // Keep the ranges feasible for a strictly increasing placement.
    for (var m = 1; m < toks.length; m++) {
      toks[m].lo = math.max(toks[m].lo, toks[m - 1].lo + 1);
    }
    for (var m = toks.length - 1; m >= 0; m--) {
      final cap = m + 1 < toks.length ? toks[m + 1].hi - 1 : _cells;
      toks[m].hi = math.max(toks[m].lo + 1, math.min(toks[m].hi, cap));
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
    double penalty(double dv, double avg, double weight) {
      var p = 0.0;
      if (dv < 0.04) {
        p += 25;
      } else if (dv < 0.08) {
        p += 4;
      }
      final max = maxSeconds(weight);
      if (dv > max) p += 10 + (dv - max) * 5;
      final l = math.log(math.max(dv, 0.02) / (avg * weight));
      return p + 0.35 * l * l;
    }

    final penTables = <int, Float64List>{};
    Float64List penTable(int line, double weight) {
      final key = line * 64 + (weight * 4).round().clamp(0, 63);
      return penTables.putIfAbsent(key, () {
        final size = maxRaw * g + 1;
        final tab = Float64List(size);
        for (var v = 0; v < size; v++) {
          tab[v] = penalty(v * hop, lineAvg[line], weight);
        }
        return tab;
      });
    }

    // Voiced frames of a slot that belong to the same phrase as its start.
    int connectedVoiced(int a, int b) => _voicedPrefix[math.min(b, _nextBreak[a])] - _voicedPrefix[a];
    double voicedPen(_Tok tok, int fromCell, int toCell) {
      final a = math.min(fromCell * g, t.length), b = math.min(toCell * g, t.length);
      final v = connectedVoiced(a, b);
      final tab = penTable(tok.line, tok.weight);
      if (v < tab.length) return tab[v];
      return penalty(v * hop, lineAvg[tok.line], tok.weight);
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
      final tab = penTable(prev.line, prev.weight);
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
    }
    // Close the last character at the end of its window.
    final last = toks.last;
    final endCell = last.hi;
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

    // Build the reference.
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
        final s = starts[first] * g;
        final e = m < toks.length ? starts[m] * g : endCell * g;
        final (vs, ve) = _voicedExtent(s, math.max(s + 1, e));
        final notes = ve > vs ? _notes(vs, ve) : <RefNote>[];
        final onset = _onset(toks[first], starts[first]);
        refTokens.add(RefToken(
          text: line.tokens[i].text,
          start: vs * hop,
          end: ve > vs ? ve * hop : (s + (0.25 / hop).round()) * hop,
          notes: notes,
          spaceBefore: line.tokens[i].spaceBefore,
          confidence: notes.isEmpty ? 0 : (0.4 + onset / 6).clamp(0.0, 1.0).toDouble(),
        ));
      }
      out.add(RefLine(
        index: k,
        text: line.text,
        lrcStart: line.start,
        lrcEnd: k + 1 < lines.length ? lines[k + 1].start : null,
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
  (int, int) _voicedExtent(int s, int e) {
    final n = t.length;
    e = math.min(e, n);
    var a = s;
    final maxLead = (0.25 / hop).round();
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

  /// Voiced runs `[start, end)` inside `[a, b)`.
  List<(int, int)> _runs(int a, int b) {
    final out = <(int, int)>[];
    var i = a;
    while (i < b) {
      if (!t.voiced(i)) {
        i++;
        continue;
      }
      var j = i;
      while (j < b && t.voiced(j)) {
        j++;
      }
      out.add((i, j));
      i = j;
    }
    return out;
  }

  /// Splits the voiced frames of `[s, e)` into stable notes.
  List<RefNote> _notes(int s, int e) {
    final notes = <RefNote>[];
    final minFrames = math.max(2, (o.minNoteSeconds / hop).round());
    for (final (rs, re) in _runs(s, e)) {
      var start = rs;
      final vals = <double>[t.midi[rs]];
      var i = rs + 1;
      while (i < re) {
        final med = median(vals.length > 12 ? vals.sublist(vals.length - 12) : vals);
        final v = t.midi[i];
        if ((v - med).abs() > o.noteSplitSemitones) {
          var persist = 0;
          for (var k = i; k < math.min(re, i + 4); k++) {
            if ((t.midi[k] - med).abs() > o.noteSplitSemitones) persist++;
          }
          if (persist >= 4 && i - start >= minFrames) {
            notes.add(_makeNote(start, i));
            start = i;
            vals.clear();
          }
        }
        vals.add(v);
        i++;
      }
      notes.add(_makeNote(start, re));
    }
    var changed = true;
    while (changed && notes.length > 1) {
      changed = false;
      for (var k = 0; k < notes.length; k++) {
        final nk = notes[k];
        if (nk.duration >= o.minNoteSeconds) continue;
        final left = k > 0 ? notes[k - 1] : null;
        final right = k + 1 < notes.length ? notes[k + 1] : null;
        RefNote? target;
        if (left != null && (left.end - nk.start).abs() < 2 * hop) target = left;
        if (right != null && (right.start - nk.end).abs() < 2 * hop) {
          if (target == null || (right.midi - nk.midi).abs() < (target.midi - nk.midi).abs()) {
            target = right;
          }
        }
        if (target == null) continue;
        target.start = math.min(target.start, nk.start);
        target.end = math.max(target.end, nk.end);
        notes.removeAt(k);
        changed = true;
        break;
      }
    }
    for (var k = notes.length - 1; k > 0; k--) {
      final a = notes[k - 1], b = notes[k];
      if ((a.midi - b.midi).abs() < 0.5 && (b.start - a.end) < 2 * hop) {
        final w = a.duration + b.duration;
        a.midi = (a.midi * a.duration + b.midi * b.duration) / w;
        a.end = b.end;
        notes.removeAt(k);
      }
    }
    notes.removeWhere((n) => n.duration < 0.04);
    return notes;
  }

  RefNote _makeNote(int s, int e) {
    final vals = <double>[for (var k = s; k < e; k++) t.midi[k]];
    return RefNote(start: s * hop, end: e * hop, midi: median(vals));
  }
}
