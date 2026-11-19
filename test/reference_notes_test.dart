import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference_notes.dart';

/// The import's frame grid (128 samples at 22.05 kHz, 5.8 ms).
const _hop = 128 / 22050;

/// A track with the contour [midiAt] (0 = unvoiced) over [seconds].
PitchTrack _track(double seconds, double Function(double t) midiAt) {
  final n = (seconds / _hop).ceil();
  final midi = Float32List(n);
  for (var i = 0; i < n; i++) {
    midi[i] = midiAt(i * _hop);
  }
  return PitchTrack(
    hopSeconds: _hop,
    midi: midi,
    rmsDb: Float32List(n)..fillRange(0, n, -20),
    aperiodicity: Float32List(n),
  );
}

List<(double, double, double)> _notes(PitchTrack t, double from, double to) => [
  for (final n in notesInFrames(t, t.frameAt(from), t.frameAt(to), splitSemitones: 0.8, minNoteSeconds: 0.06))
    (n.start, n.end, n.midi),
];

void main() {
  test('a held note with wide vibrato is one note at its centre', () {
    // ±1.3 semitones at 5.5 Hz, as a singer holds the last word of a line.
    final t = _track(1.2, (t) => t >= 0.1 && t < 1.1 ? 60 + 1.3 * math.sin(2 * math.pi * 5.5 * t) : 0);
    final notes = _notes(t, 0, 1.2);
    expect(notes, hasLength(1));
    expect(notes.single.$3, closeTo(60, 0.3));
    expect(notes.single.$1, closeTo(0.1, 0.01));
    expect(notes.single.$2, closeTo(1.1, 0.01));
  });

  test('a change of note is a new note, also two quick ones', () {
    final t = _track(1.0, (t) => t < 0.05 ? 0 : (t < 0.35 ? 60 : (t < 0.5 ? 62 : (t < 0.65 ? 64 : (t < 0.95 ? 62 : 0)))));
    final notes = _notes(t, 0, 1.0);
    expect([for (final n in notes) n.$3.round()], [60, 62, 64, 62]);
    expect(notes[1].$1, closeTo(0.35, 0.04));
    expect(notes[2].$1, closeTo(0.5, 0.04));
  });

  test('a scoop into a note does not pull the note down', () {
    // 250 ms glide from a ninth below, then a short hold: 也 in a chorus.
    final t = _track(0.5, (t) {
      if (t < 0.05 || t >= 0.4) return 0;
      if (t < 0.3) return 46 + 12 * (t - 0.05) / 0.25;
      return 58;
    });
    final notes = _notes(t, 0, 0.5);
    expect(notes, hasLength(1));
    expect(notes.single.$3, closeTo(58, 0.3));
  });

  test('a held note that briefly loses its pitch is not broken up', () {
    final t = _track(1.5, (t) => (t >= 0.1 && t < 0.7) || (t >= 0.78 && t < 1.4) ? 65 : 0);
    final notes = _notes(t, 0, 1.5);
    expect(notes, hasLength(1));
    expect(notes.single.$1, closeTo(0.1, 0.01));
    expect(notes.single.$2, closeTo(1.4, 0.01));
  });

  test('a fall at the end of a note is part of the note', () {
    final t = _track(0.8, (t) {
      if (t < 0.1 || t >= 0.68) return 0;
      if (t < 0.6) return 62;
      return 62 - 5 * (t - 0.6) / 0.08;
    });
    final notes = _notes(t, 0, 0.8);
    expect(notes, hasLength(1));
    expect(notes.single.$3, closeTo(62, 0.2));
  });
}
