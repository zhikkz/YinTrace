import 'dart:math' as math;

import '../analysis/reference.dart';
import '../dsp/pitch.dart';
import 'live_pitch.dart';

/// How a live sample compares to the reference note at the same time.
enum PitchVerdict { great, ok, off, noReference }

enum TokenIssue {
  missed('没唱出来'),
  sharp('偏高'),
  flat('偏低'),
  unstable('不稳'),
  early('抢拍'),
  late('进晚了');

  const TokenIssue(this.label);
  final String label;
}

class ScoringOptions {
  const ScoringOptions({
    this.greatCents = 50,
    this.okCents = 100,
    this.octaveTolerant = true,
    this.transpose = 0,
  });

  /// Deviation counted as "on pitch".
  final double greatCents;

  /// Deviation counted as "close".
  final double okCents;

  /// Ignore octave differences (e.g. a male voice singing a female song).
  final bool octaveTolerant;

  /// Semitones added to the reference (sing in another key).
  final int transpose;
}

/// A point of the singer's pitch trail as drawn on the graph.
class UserPoint {
  const UserPoint(this.time, this.midi, this.verdict);
  final double time;

  /// 0 = no voice.
  final double midi;
  final PitchVerdict verdict;
}

class ScoredSample {
  const ScoredSample(this.pitch, this.verdict, this.deviationCents, this.referenceMidi);
  final LivePitch pitch;
  final PitchVerdict verdict;

  /// Signed deviation from the reference (positive = sharp), null when not
  /// comparable.
  final double? deviationCents;
  final double? referenceMidi;
}

class _Acc {
  int frames = 0;
  int voiced = 0;
  int great = 0;
  int ok = 0;
  double sum = 0;
  double sum2 = 0;
  final devs = <double>[];

  void clear() {
    frames = voiced = great = ok = 0;
    sum = sum2 = 0;
    devs.clear();
  }
}

class TokenResult {
  TokenResult({
    required this.token,
    required this.score,
    required this.coverage,
    required this.attempted,
    this.medianCents,
    this.stdCents,
    this.timingOffset,
    this.issues = const {},
  });

  final RefToken token;

  /// 0..100 (NaN when the token has no pitch reference).
  final double score;
  final double coverage;
  final bool attempted;
  final double? medianCents;
  final double? stdCents;

  /// Singer's onset minus reference onset (seconds), when detected.
  final double? timingOffset;
  final Set<TokenIssue> issues;

  String get summary {
    if (!attempted) return '未练习';
    if (issues.isEmpty) return '很好';
    return issues.map((i) {
      if ((i == TokenIssue.sharp || i == TokenIssue.flat) && medianCents != null) {
        return '${i.label} ${medianCents!.abs().round()} 音分';
      }
      return i.label;
    }).join('，');
  }
}

class LineResult {
  LineResult(this.line, this.score, this.tokens, this.attempted);
  final RefLine line;
  final double score;
  final List<TokenResult> tokens;
  final bool attempted;

  Iterable<TokenResult> get problems => tokens.where((t) => t.attempted && t.issues.isNotEmpty);
}

/// Compares live pitch against the per-character reference.
class PracticeScorer {
  PracticeScorer(this.reference, {this.options = const ScoringOptions(), this.sampleInterval = 0.01}) {
    for (var l = 0; l < reference.lines.length; l++) {
      final line = reference.lines[l];
      for (var k = 0; k < line.tokens.length; k++) {
        for (final n in line.tokens[k].notes) {
          _notes.add((n, l, k));
        }
      }
    }
    _notes.sort((a, b) => a.$1.start.compareTo(b.$1.start));
    _acc = List.generate(_notes.length, (_) => _Acc());
    _onsets = {
      for (var l = 0; l < reference.lines.length; l++)
        for (var k = 0; k < reference.lines[l].tokens.length; k++) (l, k): null
    };
  }

  final SongReference reference;
  ScoringOptions options;

  /// Seconds between live pitch samples (the tracker hop).
  final double sampleInterval;
  final _notes = <(RefNote, int, int)>[];
  late final List<_Acc> _acc;
  late final Map<(int, int), double?> _onsets;
  double _lastTime = -1e9;
  double _unvoicedSince = -1e9;
  bool _wasVoiced = false;

  /// Completed passes per line (line index -> scores in order).
  final Map<int, List<double>> linePasses = {};
  final Set<int> _lineOpen = {};

  /// Signed cents between a sung MIDI value and a reference MIDI value.
  double deviation(double sung, double ref) {
    var d = sung - (ref + options.transpose);
    if (options.octaveTolerant) d -= 12 * (d / 12).roundToDouble();
    return d * 100;
  }

  /// Index of the note sounding at [t], or -1.
  int _find(double t) {
    // Notes do not overlap, so their ends are sorted too: binary search the
    // first note that ends after t.
    var lo = 0, hi = _notes.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_notes[mid].$1.end <= t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    if (lo < _notes.length && _notes[lo].$1.start <= t) return lo;
    return -1;
  }

  /// Forgets everything sung after [t] (used when seeking or looping back).
  void resetFrom(double t) {
    for (var i = 0; i < _notes.length; i++) {
      if (_notes[i].$1.end > t) _acc[i].clear();
    }
    for (final key in _onsets.keys) {
      final tok = reference.lines[key.$1].tokens[key.$2];
      if (tok.start >= t - 0.35) _onsets[key] = null;
    }
    _lineOpen.clear();
  }

  ScoredSample add(LivePitch p) {
    if (!p.playing) return ScoredSample(p, PitchVerdict.noReference, null, null);
    final t = p.songTime;
    if (t < _lastTime - 0.25) resetFrom(t);
    _closeFinishedLines(t);
    _lastTime = t;
    _trackOnsets(p);

    final idx = _find(t);
    if (idx < 0) return ScoredSample(p, PitchVerdict.noReference, null, null);
    final (note, l, _) = _notes[idx];
    _lineOpen.add(l);
    final acc = _acc[idx];
    acc.frames++;
    if (!p.voiced) return ScoredSample(p, PitchVerdict.off, null, note.midi + options.transpose);
    final dev = deviation(p.midi, note.midi);
    acc.voiced++;
    acc.sum += dev;
    acc.sum2 += dev * dev;
    acc.devs.add(dev);
    final a = dev.abs();
    PitchVerdict v;
    if (a <= options.greatCents) {
      acc.great++;
      v = PitchVerdict.great;
    } else if (a <= options.okCents) {
      acc.ok++;
      v = PitchVerdict.ok;
    } else {
      v = PitchVerdict.off;
    }
    return ScoredSample(p, v, dev, note.midi + options.transpose);
  }

  void _trackOnsets(LivePitch p) {
    final t = p.songTime;
    if (p.voiced && !_wasVoiced && t - _unvoicedSince >= 0.06) {
      // A new sung onset. Attribute it to the character being sung (the
      // latest one that started up to 0.35 s ago); otherwise to the next
      // character if it is about to start (an early entry).
      final li = reference.lineIndexAt(t);
      (int, int)? current, upcoming;
      var currentStart = -1e9, upcomingStart = 1e9;
      for (var l = math.max(0, li - 1); l < math.min(reference.lines.length, li + 2); l++) {
        final toks = reference.lines[l].tokens;
        for (var k = 0; k < toks.length; k++) {
          if (_onsets[(l, k)] != null) continue;
          final st = toks[k].start;
          if (st <= t + 0.02 && t - st <= 0.35 && st > currentStart) {
            current = (l, k);
            currentStart = st;
          } else if (st > t + 0.02 && st - t <= 0.3 && st < upcomingStart) {
            upcoming = (l, k);
            upcomingStart = st;
          }
        }
      }
      final target = current ?? upcoming;
      if (target != null) _onsets[target] = t;
    }
    if (!p.voiced && _wasVoiced) _unvoicedSince = t;
    _wasVoiced = p.voiced;
  }

  void _closeFinishedLines(double t) {
    final done = <int>[];
    for (final l in _lineOpen) {
      if (t > reference.lines[l].end + 0.3) done.add(l);
    }
    for (final l in done) {
      _lineOpen.remove(l);
      final r = lineResult(l);
      if (r.attempted) linePasses.putIfAbsent(l, () => []).add(r.score);
    }
  }

  double _noteScore(_Acc a) {
    if (a.frames == 0) return 0;
    final coverage = a.voiced / a.frames;
    if (a.voiced == 0) return 0;
    final hit = (a.great + 0.5 * a.ok) / a.voiced;
    final med = median(a.devs).abs();
    final closeness = math.max(0.0, 1 - med / 200);
    return 100 * math.min(1.0, coverage / 0.8) * (0.7 * hit + 0.3 * closeness);
  }

  TokenResult tokenResult(int l, int k) {
    final tok = reference.lines[l].tokens[k];
    var frames = 0, voiced = 0;
    var scoreSum = 0.0, durSum = 0.0, expected = 0.0;
    final devs = <double>[];
    for (var i = 0; i < _notes.length; i++) {
      final (n, nl, nk) = _notes[i];
      if (nl != l || nk != k) continue;
      final a = _acc[i];
      expected += n.duration;
      if (a.frames == 0) continue;
      frames += a.frames;
      voiced += a.voiced;
      scoreSum += _noteScore(a) * n.duration;
      durSum += n.duration;
      devs.addAll(a.devs);
    }
    // Attempted when at least half of the token's notes were heard.
    final attempted = expected > 0 && frames * sampleInterval >= 0.5 * expected;
    if (!attempted) {
      return TokenResult(token: tok, score: double.nan, coverage: 0, attempted: false);
    }
    final coverage = frames > 0 ? voiced / frames : 0.0;
    final score = durSum > 0 ? scoreSum / durSum : 0.0;
    double? med, std;
    if (devs.isNotEmpty) {
      med = median(devs);
      final mean = devs.reduce((a, b) => a + b) / devs.length;
      std = math.sqrt(devs.map((d) => (d - mean) * (d - mean)).reduce((a, b) => a + b) / devs.length);
    }
    final onset = _onsets[(l, k)];
    final timing = onset == null ? null : onset - tok.start;
    final issues = <TokenIssue>{};
    if (coverage < 0.35) {
      issues.add(TokenIssue.missed);
    } else {
      if (med != null && med > options.greatCents) issues.add(TokenIssue.sharp);
      if (med != null && med < -options.greatCents) issues.add(TokenIssue.flat);
      if (std != null && std > 70) issues.add(TokenIssue.unstable);
      if (timing != null && timing > 0.15) issues.add(TokenIssue.late);
      if (timing != null && timing < -0.15) issues.add(TokenIssue.early);
    }
    return TokenResult(
      token: tok,
      score: score,
      coverage: coverage,
      attempted: true,
      medianCents: med,
      stdCents: std,
      timingOffset: timing,
      issues: issues,
    );
  }

  LineResult lineResult(int l) {
    final line = reference.lines[l];
    final tokens = [for (var k = 0; k < line.tokens.length; k++) tokenResult(l, k)];
    var s = 0.0, w = 0.0;
    for (final t in tokens) {
      if (!t.attempted || t.score.isNaN) continue;
      final d = t.token.notes.fold<double>(0, (a, n) => a + n.duration);
      s += t.score * d;
      w += d;
    }
    final attempted = w > 0;
    return LineResult(line, attempted ? s / w : double.nan, tokens, attempted);
  }

  List<LineResult> results() => [for (var l = 0; l < reference.lines.length; l++) lineResult(l)];

  /// Duration weighted score of all attempted lines (NaN when none).
  double overallScore([List<LineResult>? lines]) {
    final rs = lines ?? results();
    var s = 0.0, w = 0.0;
    for (final r in rs) {
      if (!r.attempted) continue;
      final d = r.line.notes.fold<double>(0, (a, n) => a + n.duration);
      s += r.score * d;
      w += d;
    }
    return w > 0 ? s / w : double.nan;
  }
}
