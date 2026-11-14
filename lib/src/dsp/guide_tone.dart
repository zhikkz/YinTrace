import 'dart:math' as math;
import 'dart:typed_data';

import 'pitch.dart';

/// A soft guide tone for [notes] — (start, end, MIDI) in seconds — between
/// [from] and [to] seconds, mono. The fundamental with two weaker
/// harmonics, so the pitch is easy to hear next to a voice, and short fades
/// at every note so neighbouring notes stay apart.
Float32List guideTone(
  Iterable<(double, double, double)> notes,
  double from,
  double to, {
  int sampleRate = 44100,
  double level = 0.22,
}) {
  final n = math.max(0, ((to - from) * sampleRate).round());
  final out = Float32List(n);
  final attack = 0.015 * sampleRate, release = 0.04 * sampleRate;
  for (final (start, end, midi) in notes) {
    final a = math.max(0, ((start - from) * sampleRate).round());
    final b = math.min(n, ((end - from) * sampleRate).round());
    if (b <= a) continue;
    final w = 2 * math.pi * midiToHz(midi) / sampleRate;
    final len = b - a;
    for (var i = 0; i < len; i++) {
      var env = 1.0;
      if (i < attack) env = 0.5 - 0.5 * math.cos(math.pi * i / attack);
      final tail = len - 1 - i;
      if (tail < release) env = math.min(env, 0.5 - 0.5 * math.cos(math.pi * tail / release));
      final ph = w * i;
      out[a + i] += level * env * (math.sin(ph) + 0.35 * math.sin(2 * ph) + 0.15 * math.sin(3 * ph)) / 1.5;
    }
  }
  return out;
}
