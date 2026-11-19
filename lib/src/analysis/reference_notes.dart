import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import 'pitch_track.dart';
import 'reference.dart';

/// Voiced runs `[start, end)` inside `[a, b)`.
List<(int, int)> _runs(PitchTrack track, int a, int b) {
  final out = <(int, int)>[];
  var i = a;
  while (i < b) {
    if (!track.voiced(i)) {
      i++;
      continue;
    }
    var j = i;
    while (j < b && track.voiced(j)) {
      j++;
    }
    out.add((i, j));
    i = j;
  }
  return out;
}

/// The notes a singer holds in the voiced frames of `[s, e)`: what the
/// guide line draws and what the singer is scored against.
///
/// A held note is not a flat line in the contour: it has vibrato (on the
/// two songs this was tuned on, up to ±1.5 semitones at 5–6 Hz), a scoop
/// into it and a fall at its end. Cutting the contour wherever it moves by
/// more than [splitSemitones] cuts every vibrato swing into a note of its
/// own, and the guide zigzags. Instead:
///
/// 1. the contour is smoothed with a running median over
///    [_vibratoSeconds] (about one vibrato cycle), which leaves the notes
///    and removes the vibrato;
/// 2. the smoothed contour is assigned to semitones with a Viterbi pass in
///    which staying on a note is free and changing note costs as much as
///    [_changeCost] frames sung a semitone off, so only a real change of
///    note, held for some time, starts a new note;
/// 3. a glide (a scoop into a note, a fall at its end, a slide between two
///    notes: where even the smoothed contour keeps moving) is not a note:
///    its frames go to the notes on either side, each to the one nearer in
///    pitch. Notes shorter than [minNoteSeconds] join the neighbour nearer
///    in pitch;
/// 4. a note's pitch is the mean of the frames where it was held (not of
///    what joined it), around their median: vibrato gives its centre, an
///    octave slip of a few frames nothing;
/// 5. neighbouring notes within [splitSemitones] of each other become one,
///    also across a gap of up to [_bridgeSeconds] where the voice briefly
///    lost its pitch: the guide does not break up a held note.
List<RefNote> notesInFrames(
  PitchTrack track,
  int s,
  int e, {
  required double splitSemitones,
  required double minNoteSeconds,
}) {
  final hop = track.hopSeconds;
  final notes = <RefNote>[];
  for (final (rs, re) in _runs(track, s, e)) {
    final run = _Run(track, rs, re);
    for (final n in run.notes(minFrames: math.max(2, (minNoteSeconds / hop).round()))) {
      notes.add(RefNote(start: track.timeOf(n.start), end: track.timeOf(n.end), midi: run.pitch(n)));
    }
  }
  for (var k = notes.length - 1; k > 0; k--) {
    final a = notes[k - 1], b = notes[k];
    if ((a.midi - b.midi).abs() < splitSemitones && (b.start - a.end) < math.max(2 * hop, _bridgeSeconds)) {
      final w = a.duration + b.duration;
      a.midi = (a.midi * a.duration + b.midi * b.duration) / w;
      a.end = b.end;
      notes.removeAt(k);
    }
  }
  notes.removeWhere((n) => n.duration < 0.04);
  return notes;
}

/// About one vibrato cycle (5–7 Hz).
const _vibratoSeconds = 0.16;

/// Notes of the same pitch this close together are one held note.
const _bridgeSeconds = 0.1;

/// Changing note costs as much as this many frames a semitone off.
const _changeCost = 5.0;

/// Where the smoothed contour moves faster than this (semitones per
/// second), the voice glides; vibrato hardly moves it.
const _glideSlope = 20.0;

/// A stretch of one note: frames `[start, end)` of the track, of which
/// `[coreStart, coreEnd)` is where the note was found (what joined it
/// later is not).
class _Note {
  _Note(this.start, this.end) : coreStart = start, coreEnd = end;
  int start, end, coreStart, coreEnd;
  int get length => end - start;
}

/// A voiced run `[rs, re)` of the track.
class _Run {
  _Run(this.track, this.rs, this.re) {
    final n = re - rs;
    final half = math.max(1, (_vibratoSeconds / track.hopSeconds / 2).round());
    // A running median: the centre of a vibrato cycle, while a step from
    // one note to the next stays a step (an average would make it a ramp
    // through the semitones between them) and a glide stays a glide.
    smooth = Float64List(n);
    final window = <double>[];
    for (var i = 0; i < n; i++) {
      final a = math.max(0, i - half), b = math.min(n, i + half + 1);
      window
        ..clear()
        ..addAll(Float32List.sublistView(track.midi, rs + a, rs + b));
      smooth[i] = median(window);
    }
    gliding = List<bool>.generate(n, (i) {
      final a = math.max(0, i - 2), b = math.min(n - 1, i + 2);
      return b > a && (smooth[b] - smooth[a]).abs() / ((b - a) * track.hopSeconds) > _glideSlope;
    });
  }

  final PitchTrack track;
  final int rs, re;
  late final Float64List smooth;
  late final List<bool> gliding;

  double midi(int frame) => track.midi[frame];

  List<_Note> notes({required int minFrames}) {
    final notes = [for (final (a, b) in _semitones()) _Note(a, b)];
    // Glides first: a stretch the voice glides through most of the time.
    bool glide(_Note n) {
      var g = 0;
      for (var i = n.coreStart; i < n.coreEnd; i++) {
        if (gliding[i - rs]) g++;
      }
      return 2 * g > n.coreEnd - n.coreStart;
    }

    while (notes.length > 1) {
      final k = notes.indexWhere(glide);
      if (k < 0) break;
      final n = notes.removeAt(k);
      final left = k > 0 ? notes[k - 1] : null, right = k < notes.length ? notes[k] : null;
      if (left == null) {
        right!.start = n.start;
      } else if (right == null) {
        left.end = n.end;
      } else {
        // Each frame to the note nearer in pitch: a glide is monotonic,
        // so this splits it once.
        final l = pitch(left), r = pitch(right);
        var split = n.start;
        while (split < n.end && (midi(split) - l).abs() <= (midi(split) - r).abs()) {
          split++;
        }
        left.end = split;
        right.start = split;
      }
    }
    // Then notes too short to be held, the shortest first.
    while (notes.length > 1) {
      var k = -1;
      for (var j = 0; j < notes.length; j++) {
        if (notes[j].length < minFrames && (k < 0 || notes[j].length < notes[k].length)) k = j;
      }
      if (k < 0) break;
      final n = notes.removeAt(k);
      final left = k > 0 ? notes[k - 1] : null, right = k < notes.length ? notes[k] : null;
      final m = pitch(n);
      final toLeft = right == null || (left != null && (pitch(left) - m).abs() <= (pitch(right) - m).abs());
      if (toLeft) {
        left!.end = n.end;
      } else {
        right.start = n.start;
      }
    }
    return notes;
  }

  /// The note's pitch: the mean of its core within 3 semitones of the
  /// core's median.
  double pitch(_Note n) {
    final values = [for (var i = n.coreStart; i < n.coreEnd; i++) midi(i)];
    final m = median(values);
    var sum = 0.0, count = 0;
    for (final v in values) {
      if ((v - m).abs() <= 3) {
        sum += v;
        count++;
      }
    }
    return count == 0 ? m : sum / count;
  }

  /// The run split into stretches of one semitone of the smoothed contour.
  List<(int, int)> _semitones() {
    final n = re - rs;
    var lo = double.infinity, hi = -double.infinity;
    for (final v in smooth) {
      lo = math.min(lo, v);
      hi = math.max(hi, v);
    }
    final base = lo.floor() - 1;
    final states = hi.ceil() + 1 - base + 1;
    // A frame a semitone off costs 1.
    double cost(int i, int k) {
      final d = smooth[i] - (base + k);
      return d * d;
    }

    final back = Uint16List(n * states);
    var prev = Float64List(states), next = Float64List(states);
    for (var k = 0; k < states; k++) {
      prev[k] = cost(0, k);
    }
    for (var i = 1; i < n; i++) {
      var best = 0;
      for (var k = 1; k < states; k++) {
        if (prev[k] < prev[best]) best = k;
      }
      final change = prev[best] + _changeCost;
      for (var k = 0; k < states; k++) {
        if (prev[k] <= change) {
          next[k] = prev[k] + cost(i, k);
          back[i * states + k] = k;
        } else {
          next[k] = change + cost(i, k);
          back[i * states + k] = best;
        }
      }
      final swap = prev;
      prev = next;
      next = swap;
    }
    var k = 0;
    for (var j = 1; j < states; j++) {
      if (prev[j] < prev[k]) k = j;
    }
    final path = Uint16List(n);
    for (var i = n - 1; i >= 0; i--) {
      path[i] = k;
      k = back[i * states + k];
    }
    final out = <(int, int)>[];
    var start = 0;
    for (var i = 1; i <= n; i++) {
      if (i == n || path[i] != path[start]) {
        out.add((rs + start, rs + i));
        start = i;
      }
    }
    return out;
  }
}
