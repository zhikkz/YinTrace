import 'dart:math' as math;
import 'dart:typed_data';

import 'scoring.dart';

/// What the singer sang in this practice session, on the song's timeline,
/// so it can be played back together with the accompaniment.
///
/// Every captured block is placed where the singer heard it: the song frame
/// that was playing when it was captured, minus the latency compensation
/// that the pitch tracking uses as well. Singing a passage again (after a
/// seek, or in a line loop) overwrites the earlier take of that passage.
/// Kept in memory only: about 10 MB per minute of song.
class TakeRecorder {
  TakeRecorder({required this.sampleRate, required this.lengthFrames});

  final int sampleRate;

  /// Length of the song; the take covers at most this.
  final int lengthFrames;

  Float32List? _samples;
  int _first = -1;
  int _end = -1;
  int _version = 0;

  /// The singer's pitch while recording, in song time order. Like the audio,
  /// a passage sung again replaces the earlier take of the same passage.
  final List<UserPoint> points = [];
  int _cursor = -1; // index of the newest point of the current pass

  bool get isEmpty => _samples == null;

  /// Mono samples of the whole song (silent where nothing was sung).
  Float32List? get samples => _samples;

  /// Changes whenever audio is added (to reload a played-back copy).
  int get version => _version;

  /// Song time span that contains everything recorded.
  double get startSeconds => _first < 0 ? 0 : _first / sampleRate;
  double get endSeconds => _end < 0 ? 0 : _end / sampleRate;

  /// Whether any audio was recorded between [from] and [to] seconds.
  bool covers(double from, double to) =>
      !isEmpty && _first < (to * sampleRate).round() && _end > (from * sampleRate).round();

  /// Adds a captured block whose first sample was captured while song frame
  /// [songFrame] was playing. Only the part heard between song frames
  /// [fromFrame] and [toFrame] is kept: outside them the singer was waiting
  /// for their line, and what was recorded there before stays.
  void addAudio(Float32List block, int songFrame, int latencyFrames, {int fromFrame = 0, int? toFrame}) {
    final start = songFrame - latencyFrames;
    final a = math.max(math.max(0, fromFrame), start);
    final b = math.min(math.min(lengthFrames, toFrame ?? lengthFrames), start + block.length);
    if (a >= b) return;
    final buf = _samples ??= Float32List(lengthFrames);
    buf.setRange(a, b, block, a - start);
    _first = _first < 0 ? a : math.min(_first, a);
    _end = math.max(_end, b);
    _version++;
  }

  void addPoint(UserPoint p) {
    const same = 0.004; // points are about 10 ms apart
    var i = _cursor; // p goes after index i
    final continues =
        i >= 0 && i < points.length && points[i].time <= p.time && p.time - points[i].time < 0.25;
    if (!continues) i = _firstAtOrAfter(p.time - same) - 1;
    // Points of an earlier take between this pass's previous point and p.
    var j = i + 1;
    while (j < points.length && points[j].time <= p.time + same) {
      j++;
    }
    points.removeRange(i + 1, j);
    points.insert(i + 1, p);
    _cursor = i + 1;
  }

  int _firstAtOrAfter(double t) {
    var lo = 0, hi = points.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (points[mid].time < t) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
  }

  /// The recorded pitch nearest to song time [t] (within 60 ms).
  UserPoint? pointAt(double t) {
    if (points.isEmpty) return null;
    final lo = _firstAtOrAfter(t);
    UserPoint? best;
    for (final i in [lo - 1, lo]) {
      if (i < 0 || i >= points.length) continue;
      final q = points[i];
      if ((q.time - t).abs() > 0.06) continue;
      if (best == null || (q.time - t).abs() < (best.time - t).abs()) best = q;
    }
    return best;
  }
}
