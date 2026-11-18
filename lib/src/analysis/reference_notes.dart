import 'dart:math' as math;

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

/// Splits the voiced frames of `[s, e)` into stable notes.
List<RefNote> notesInFrames(
  PitchTrack track,
  int s,
  int e, {
  required double splitSemitones,
  required double minNoteSeconds,
}) {
  final hop = track.hopSeconds;
  final notes = <RefNote>[];
  final minFrames = math.max(2, (minNoteSeconds / hop).round());
  for (final (rs, re) in _runs(track, s, e)) {
    var start = rs;
    final vals = <double>[track.midi[rs]];
    var i = rs + 1;
    while (i < re) {
      final med = median(vals.length > 12 ? vals.sublist(vals.length - 12) : vals);
      final v = track.midi[i];
      if ((v - med).abs() > splitSemitones) {
        var persist = 0;
        for (var k = i; k < math.min(re, i + 4); k++) {
          if ((track.midi[k] - med).abs() > splitSemitones) persist++;
        }
        if (persist >= 4 && i - start >= minFrames) {
          notes.add(_makeNote(track, start, i));
          start = i;
          vals.clear();
        }
      }
      vals.add(v);
      i++;
    }
    notes.add(_makeNote(track, start, re));
  }
  var changed = true;
  while (changed && notes.length > 1) {
    changed = false;
    for (var k = 0; k < notes.length; k++) {
      final nk = notes[k];
      if (nk.duration >= minNoteSeconds) continue;
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

RefNote _makeNote(PitchTrack track, int s, int e) {
  final vals = <double>[for (var k = s; k < e; k++) track.midi[k]];
  return RefNote(start: track.timeOf(s), end: track.timeOf(e), midi: median(vals));
}
