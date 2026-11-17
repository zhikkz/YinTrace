import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';

const rate = 22050;

void tone(
  Float32List audio,
  double from,
  double to,
  double hz, {
  double gain = 0.2,
}) {
  for (var i = (from * rate).round(); i < (to * rate).round(); i++) {
    audio[i] = gain * math.sin(2 * math.pi * hz * i / rate);
  }
}

void main() {
  test(
    'silence, noise and quiet tonal bleed stay unvoiced; soft singing remains',
    () {
      final audio = Float32List(rate * 3);
      tone(audio, 0.1, 0.6, 220);
      tone(audio, 0.8, 1.3, 330, gain: 0.0005);
      final rng = math.Random(42);
      for (var i = (1.5 * rate).round(); i < 2 * rate; i++) {
        audio[i] = 0.05 * (2 * rng.nextDouble() - 1);
      }
      tone(audio, 2.2, 2.7, 220, gain: 0.02);
      final t = analyzePitch(audio, rate);
      for (var f = 0; f < t.length; f++) {
        final time = t.timeOf(f);
        if ((time > 0.65 && time < 2.15) || time > 2.75) {
          expect(t.midi[f], 0, reason: 'no singing at $time');
        }
        if ((time > 0.15 && time < 0.55) || (time > 2.25 && time < 2.65)) {
          expect(t.midi[f], closeTo(57, 0.1), reason: 'voiced note at $time');
        }
      }
      expect(
        analyzePitch(Float32List(rate), rate).midi.every((m) => m == 0),
        isTrue,
      );
      expect(analyzePitch(Float32List(0), rate).length, 0);
    },
  );

  test('brief dropouts rejected by YIN are not filled back in', () {
    // Vary the gap relative to the analysis window/hop so short rejected
    // stretches as well as longer pauses are exercised.
    var rejected = 0;
    for (final gap in [0.005, 0.010, 0.015, 0.020, 0.030, 0.040]) {
      final audio = Float32List(rate);
      tone(audio, 0.1, 0.5, 220);
      tone(audio, 0.5 + gap, 0.9, 220);
      final t = analyzePitch(audio, rate);
      for (var f = t.frameAt(0.46); f <= t.frameAt(0.58); f++) {
        if (t.aperiodicity[f] > const PitchAnalysisOptions().maxAperiodicity) {
          rejected++;
          expect(
            t.midi[f],
            0,
            reason: 'rejected frame $f in a ${gap * 1000} ms gap',
          );
        }
      }
      expect(t.midiAt(0.3), closeTo(57, 0.1));
      expect(t.midiAt(0.7), closeTo(57, 0.1));
    }
    expect(rejected, greaterThan(0));
  });

  test('a short octave note between pauses is not folded into neighbouring phrases', () {
    final audio = Float32List(rate);
    tone(audio, 0.1, 0.4, 220);
    tone(audio, 0.43, 0.51, 440);
    tone(audio, 0.54, 0.9, 220);
    final t = analyzePitch(audio, rate);
    expect(t.midiAt(0.3), closeTo(57, 0.1));
    expect(t.midiAt(0.47), closeTo(69, 0.1));
    expect(t.midiAt(0.7), closeTo(57, 0.1));
    // The 46 ms analysis window can overlap a note at the edge of a pause;
    // there must still be a real break between each pair of phrases.
    for (final (from, to) in [(0.4, 0.43), (0.51, 0.54)]) {
      expect(
        t.midi.sublist(t.frameAt(from), t.frameAt(to) + 1),
        contains(0),
        reason: 'pause from $from to $to',
      );
    }
  });
}
