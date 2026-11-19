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
/// Allocates sample blocks only for the passages that reach the recorder.
class TakeRecorder {
  TakeRecorder({required this.sampleRate, required this.lengthFrames});

  final int sampleRate;

  /// Length of the song; the take covers at most this.
  final int lengthFrames;

  static const _chunkFrames = 4096;
  final _chunks = <int, Float32List>{};
  // Sorted, disjoint captured ranges, with exclusive ends.
  final _recordedRanges = <({int start, int end})>[];
  int _version = 0;

  /// The singer's pitch while recording, in song time order. Like the audio,
  /// a passage sung again replaces the earlier take of the same passage.
  final List<UserPoint> points = [];
  int _cursor = -1; // index of the newest point of the current pass

  bool get isEmpty => _recordedRanges.isEmpty;

  /// How long a voice was heard in the take (the points with a pitch, one
  /// per [hopSeconds]); the audio itself is recorded whether anyone sings
  /// or not.
  double voicedSeconds({double hopSeconds = 0.01}) => _voiced * hopSeconds;

  /// How many of [points] have a pitch, kept up to date as they come and
  /// are replaced (asked for on every frame).
  int _voiced = 0;

  /// Allocated mono sample capacity, in frames.
  int get allocatedFrames => _chunks.length * _chunkFrames;
  int get startFrame => isEmpty ? 0 : _recordedRanges.first.start;
  int get endFrame => isEmpty ? 0 : _recordedRanges.last.end;

  /// A snapshot from frame [from] up to (but excluding) [to]. Unrecorded frames are silent.
  Float32List readFrames(int from, int to) {
    RangeError.checkValidRange(from, to, lengthFrames);
    final out = Float32List(to - from);
    for (var at = from; at < to;) {
      final offset = at % _chunkFrames;
      final count = math.min(to - at, _chunkFrames - offset);
      final chunk = _chunks[at ~/ _chunkFrames];
      if (chunk != null) out.setRange(at - from, at - from + count, chunk, offset);
      at += count;
    }
    return out;
  }

  /// Full-song snapshot for callers that need an absolute-index buffer.
  Float32List? get samples => isEmpty ? null : readFrames(0, lengthFrames);

  /// Changes whenever audio is added (to reload a played-back copy).
  int get version => _version;

  /// Song time span that contains everything recorded.
  double get startSeconds => isEmpty ? 0 : startFrame / sampleRate;
  double get endSeconds => isEmpty ? 0 : endFrame / sampleRate;

  /// Whether any captured frames, including silence, overlap [from] to [to] seconds.
  bool covers(double from, double to) {
    if (isEmpty) return false;
    final start = (from * sampleRate).round();
    final end = (to * sampleRate).round();
    if (start >= end) return false;
    final i = _firstRangeEndingAfter(start);
    return i < _recordedRanges.length && _recordedRanges[i].start < end;
  }

  /// Adds a captured block whose first sample was captured while song frame
  /// [songFrame] was playing. Only the part heard between song frames
  /// [fromFrame] and [toFrame] is kept: outside them the singer was waiting
  /// for their line, and what was recorded there before stays.
  void addAudio(Float32List block, int songFrame, int latencyFrames, {int fromFrame = 0, int? toFrame}) {
    final start = songFrame - latencyFrames;
    final a = math.max(math.max(0, fromFrame), start);
    final b = math.min(math.min(lengthFrames, toFrame ?? lengthFrames), start + block.length);
    if (a >= b) return;
    for (var at = a; at < b;) {
      final offset = at % _chunkFrames;
      final count = math.min(b - at, _chunkFrames - offset);
      final chunk = _chunks.putIfAbsent(at ~/ _chunkFrames, () => Float32List(_chunkFrames));
      chunk.setRange(offset, offset + count, block, at - start);
      at += count;
    }
    _addRecordedRange(a, b);
    _version++;
  }

  void _addRecordedRange(int start, int end) {
    // Merge touching ranges so consecutive capture blocks stay one range.
    final first = _firstRangeEndingAfter(start - 1);
    var last = first;
    while (last < _recordedRanges.length && _recordedRanges[last].start <= end) {
      final range = _recordedRanges[last++];
      start = math.min(start, range.start);
      end = math.max(end, range.end);
    }
    _recordedRanges.replaceRange(first, last, [(start: start, end: end)]);
  }

  int _firstRangeEndingAfter(int frame) {
    var lo = 0, hi = _recordedRanges.length;
    while (lo < hi) {
      final mid = (lo + hi) >> 1;
      if (_recordedRanges[mid].end <= frame) {
        lo = mid + 1;
      } else {
        hi = mid;
      }
    }
    return lo;
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
      if (points[j].midi > 0) _voiced--;
      j++;
    }
    points.removeRange(i + 1, j);
    points.insert(i + 1, p);
    if (p.midi > 0) _voiced++;
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
