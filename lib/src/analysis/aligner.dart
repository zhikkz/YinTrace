import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import 'lrc.dart';
import 'pitch_track.dart';
import 'reference.dart';

/// Tunables of the character aligner.
class AlignOptions {
  const AlignOptions({
    this.leadIn = 0.35,
    this.maxPhraseGap = 0.9,
    this.minSecondsPerToken = 0.16,
    this.maxLastLine = 12,
    this.gridFrames = 2,
    this.maxTokenSeconds = 4,
    this.noteSplitSemitones = 0.8,
    this.minNoteSeconds = 0.06,
  });

  /// Singing may start this much before the typed time stamp.
  final double leadIn;

  /// Voiced runs separated by more than this end a line (once enough
  /// material for its characters has been collected).
  final double maxPhraseGap;
  final double minSecondsPerToken;

  /// Window for the last line, which has no following time stamp.
  final double maxLastLine;

  /// Boundary search resolution in pitch frames.
  final int gridFrames;
  final double maxTokenSeconds;
  final double noteSplitSemitones;
  final double minNoteSeconds;
}

/// Builds the per-character reference melody from a pitch track and timed
/// lyrics.
///
/// For every line the voiced region after its time stamp is located, then
/// the N characters are placed on it with a dynamic programme that prefers
/// boundaries at syllable onsets (unvoiced consonant gaps, energy dips,
/// pitch changes) while keeping durations plausible. Finally the pitch
/// inside every character is split into stable notes.
SongReference buildReference(PitchTrack track, List<LyricLine> lines,
    {AlignOptions options = const AlignOptions()}) {
  final aligner = _Aligner(track, options);
  final out = <RefLine>[];
  var prevEnd = 0.0;
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    final next = i + 1 < lines.length ? lines[i + 1].start : null;
    final refLine = aligner.alignLine(i, line, prevEnd, next);
    out.add(refLine);
    if (refLine.tokens.isNotEmpty) prevEnd = math.max(prevEnd, refLine.end);
  }
  return SongReference(lines: out, duration: track.duration);
}

class _Aligner {
  _Aligner(this.t, this.o)
      : hop = t.hopSeconds,
        energy = _smooth(t.rmsDb, 2);

  final PitchTrack t;
  final AlignOptions o;
  final double hop;
  final Float32List energy;

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

  int f(double seconds) => (seconds / hop).round().clamp(0, t.length).toInt();
  double sec(int frame) => frame * hop;

  /// Voiced runs `[start, end)` inside `[a, b)`.
  List<(int, int)> runs(int a, int b) {
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

  RefLine alignLine(int index, LyricLine line, double prevEnd, double? nextStart) {
    final n = line.tokens.length;
    final w0 = math.max(prevEnd, line.start - o.leadIn);
    var w1 = nextStart != null ? nextStart - 0.03 : line.start + o.maxLastLine;
    if (line.end != null && line.end! < w1) w1 = line.end!;
    w1 = math.min(w1, t.duration);
    final a0 = f(w0), b0 = f(w1);

    final rs = b0 > a0 ? runs(a0, b0) : <(int, int)>[];
    // Ignore blips that start before the time stamp but end right away.
    final region = _pickRegion(rs, n, f(line.start));
    if (region == null) {
      return RefLine(
          index: index,
          text: line.text,
          lrcStart: line.start,
          lrcEnd: nextStart,
          tokens: _evenTokens(line, w0 < line.start ? line.start : w0, w1));
    }
    final (a, b) = region;
    final bounds = _boundaries(line.tokens, a, b);
    final tokens = <RefToken>[];
    for (var k = 0; k < n; k++) {
      final s = bounds[k].$1, e = k + 1 < n ? bounds[k + 1].$1 : b;
      final notes = _notes(s, e);
      var vs = s, ve = e;
      // Trim the slot to its voiced extent for display.
      while (vs < ve && !t.voiced(vs)) {
        vs++;
      }
      while (ve > vs && !t.voiced(ve - 1)) {
        ve--;
      }
      if (ve <= vs) {
        vs = s;
        ve = e;
      }
      tokens.add(RefToken(
        text: line.tokens[k].text,
        start: sec(vs),
        end: sec(ve),
        notes: notes,
        spaceBefore: line.tokens[k].spaceBefore,
        confidence: bounds[k].$2,
      ));
    }
    return RefLine(index: index, text: line.text, lrcStart: line.start, lrcEnd: nextStart, tokens: tokens);
  }

  (int, int)? _pickRegion(List<(int, int)> rs, int nTokens, int stampFrame) {
    if (rs.isEmpty) return null;
    final need = nTokens * o.minSecondsPerToken;
    final maxGap = (o.maxPhraseGap / hop).round();
    var startIdx = 0;
    // Skip short runs that end before the time stamp (tails of the previous
    // phrase or breaths).
    while (startIdx < rs.length - 1 && rs[startIdx].$2 <= stampFrame && (rs[startIdx].$2 - rs[startIdx].$1) * hop < 0.15) {
      startIdx++;
    }
    var a = rs[startIdx].$1, b = rs[startIdx].$2;
    var covered = (b - a) * hop;
    for (var i = startIdx + 1; i < rs.length; i++) {
      final gap = rs[i].$1 - b;
      if (gap > maxGap && covered >= need) break;
      b = rs[i].$2;
      covered += (rs[i].$2 - rs[i].$1) * hop;
    }
    if ((b - a) * hop < 0.05) return null;
    return (a, b);
  }

  List<RefToken> _evenTokens(LyricLine line, double from, double to) {
    final n = line.tokens.length;
    final span = math.max(0.2 * n, math.min(to - from, 0.35 * n));
    final step = span / n;
    return [
      for (var k = 0; k < n; k++)
        RefToken(
          text: line.tokens[k].text,
          start: from + k * step,
          end: from + (k + 1) * step,
          notes: [],
          spaceBefore: line.tokens[k].spaceBefore,
          confidence: 0,
        )
    ];
  }

  /// Onset evidence for a token starting at frame [j] (0 = none).
  double _onsetScore(int j, int a, int b) {
    if (j <= a || j >= b) return 0;
    // Unvoiced gap ending right before j.
    var g = 0;
    while (j - 1 - g >= a && !t.voiced(j - 1 - g)) {
      g++;
    }
    final voicedHere = t.voiced(j) || (j + 1 < b && t.voiced(j + 1));
    if (g >= 2 && voicedHere) {
      return 2.0 + math.min(g * hop, 0.25) / 0.05;
    }
    if (!t.voiced(j)) return 0;
    var score = 0.0;
    // Energy dip: j is (close to) a local minimum of the smoothed level.
    const r = 8;
    var isMin = true;
    for (var k = math.max(a, j - 3); k <= math.min(b - 1, j + 3); k++) {
      if (energy[k] < energy[j] - 0.01) {
        isMin = false;
        break;
      }
    }
    if (isMin) {
      var leftMax = -1e9, rightMax = -1e9;
      for (var k = math.max(a, j - r); k < j; k++) {
        leftMax = math.max(leftMax, energy[k]);
      }
      for (var k = j + 1; k <= math.min(b - 1, j + r); k++) {
        rightMax = math.max(rightMax, energy[k]);
      }
      final depth = math.min(leftMax, rightMax) - energy[j];
      if (depth >= 2) score += math.min(depth, 12) / 3;
    }
    // Pitch change between the frames before and after j.
    final left = <double>[], right = <double>[];
    for (var k = math.max(a, j - 8); k < j; k++) {
      if (t.voiced(k)) left.add(t.midi[k]);
    }
    for (var k = j; k < math.min(b, j + 8); k++) {
      if (t.voiced(k)) right.add(t.midi[k]);
    }
    if (left.length >= 3 && right.length >= 3) {
      final d = (median(right) - median(left)).abs();
      if (d >= 0.7) score += math.min(d, 4) * 0.6;
    }
    return score;
  }

  double _durationPenalty(int frames, double avg) {
    final d = frames * hop;
    var p = 0.0;
    if (d < 0.05) {
      p += 20;
    } else if (d < 0.09) {
      p += 3;
    }
    if (d > o.maxTokenSeconds) p += 10 + (d - o.maxTokenSeconds) * 5;
    final l = math.log(math.max(d, 1e-3) / avg);
    return p + 0.4 * l * l;
  }

  /// Returns (startFrame, confidence) of every token.
  List<(int, double)> _boundaries(List<LyricToken> tokens, int a, int b) {
    final n = tokens.length;
    if (n == 1) return [(a, 1.0)];
    final g = o.gridFrames;
    final grid = <int>[];
    for (var j = a; j < b; j += g) {
      grid.add(j);
    }
    final m = grid.length;
    if (m < n) {
      // Region too short: spread evenly.
      final step = (b - a) / n;
      return [for (var k = 0; k < n; k++) ((a + k * step).round(), 0.0)];
    }
    final base = Float64List(m);
    for (var x = 0; x < m; x++) {
      // Best onset evidence within the grid cell.
      var s = 0.0;
      for (var j = grid[x]; j < math.min(b, grid[x] + g); j++) {
        s = math.max(s, _onsetScore(j, a, b));
      }
      base[x] = s;
    }
    final gapAt = List<bool>.generate(m, (x) {
      final j = grid[x];
      return j - 2 >= a && !t.voiced(j - 1) && !t.voiced(j - 2);
    });
    double score(int k, int x) {
      // Token k starts at grid[x].
      var s = base[x];
      final tok = tokens[k];
      if (tok.spaceBefore) s = gapAt[x] ? s * 1.5 + 1 : s - 1;
      if (tok.time != null && (sec(grid[x]) - tok.time!).abs() < 0.08) s += 10;
      return s;
    }

    final avg = (b - a) * hop / n;
    final maxLen = math.max(1, (o.maxTokenSeconds * 1.5 / hop / g).ceil());
    // Penalty by length in grid steps (all steps are `g` frames apart).
    final pen = Float64List(m + 1);
    for (var d = 1; d <= m; d++) {
      pen[d] = _durationPenalty(d * g, avg);
    }
    const neg = -1e18;
    // dp[k][x]: best score with token k starting at grid x.
    final dp = List.generate(n, (_) => Float64List(m)..fillRange(0, m, neg));
    final from = List.generate(n, (_) => Int32List(m));
    dp[0][0] = 0;
    for (var k = 1; k < n; k++) {
      final prev = dp[k - 1];
      final cur = dp[k];
      final back = from[k];
      // token k-1 occupies grid [i, x); need at least k-1 slots before.
      for (var x = k; x <= m - (n - k); x++) {
        var best = neg;
        var arg = -1;
        final lo = math.max(k - 1, x - maxLen);
        for (var i = lo; i < x; i++) {
          final pv = prev[i];
          if (pv <= neg / 2) continue;
          final v = pv - pen[x - i];
          if (v > best) {
            best = v;
            arg = i;
          }
        }
        if (arg >= 0) {
          cur[x] = best + score(k, x);
          back[x] = arg;
        }
      }
    }
    // Close the last token at b.
    var best = neg;
    var arg = -1;
    for (var x = n - 1; x < m; x++) {
      final pv = dp[n - 1][x];
      if (pv <= neg / 2) continue;
      final v = pv - _durationPenalty(b - grid[x], avg);
      if (v > best) {
        best = v;
        arg = x;
      }
    }
    if (arg < 0) {
      final step = (b - a) / n;
      return [for (var k = 0; k < n; k++) ((a + k * step).round(), 0.0)];
    }
    final xs = List<int>.filled(n, 0);
    xs[n - 1] = arg;
    for (var k = n - 1; k > 0; k--) {
      xs[k - 1] = from[k][xs[k]];
    }
    return [
      for (var k = 0; k < n; k++)
        (k == 0 ? a : grid[xs[k]], k == 0 ? 1.0 : (base[xs[k]] / 4).clamp(0.0, 1.0).toDouble())
    ];
  }

  /// Splits the voiced frames of `[s, e)` into stable notes.
  List<RefNote> _notes(int s, int e) {
    final notes = <RefNote>[];
    final minFrames = math.max(2, (o.minNoteSeconds / hop).round());
    for (final (rs, re) in runs(s, e)) {
      var start = rs;
      final vals = <double>[t.midi[rs]];
      var i = rs + 1;
      while (i < re) {
        final med = median(vals.length > 12 ? vals.sublist(vals.length - 12) : vals);
        final v = t.midi[i];
        if ((v - med).abs() > o.noteSplitSemitones) {
          // Require the deviation to persist for a few frames.
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
    // Merge very short notes into their closest neighbour, then merge
    // neighbours at (almost) the same pitch.
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
    return RefNote(start: sec(s), end: sec(e), midi: median(vals));
  }
}
