import 'dart:math' as math;
import 'dart:typed_data';

import 'package:yintrace/src/dsp/pitch.dart';

/// One synthetic sung syllable.
class Syl {
  const Syl(this.start, this.end, this.midi, {this.unvoicedOnset = true, this.glideTo});

  /// Start of the voiced part (seconds).
  final double start;
  final double end;
  final double midi;

  /// Precede the vowel with a noise burst / silence (like "sh", "q", "d");
  /// otherwise the syllable starts with a voiced consonant (m, n, l) that
  /// only dips the level.
  final bool unvoicedOnset;

  /// Optional pitch at the end of the syllable (melisma / slide).
  final double? glideTo;
}

/// Renders a dry, voice-like signal (mono, [sr] Hz) for the syllables.
Float32List synthVoice(List<Syl> syls, double seconds,
    {int sr = 44100, int seed = 3, double noiseDb = -62}) {
  final n = (seconds * sr).round();
  final out = Float32List(n);
  final rng = math.Random(seed);
  final noiseAmp = math.pow(10, noiseDb / 20).toDouble();
  for (var i = 0; i < n; i++) {
    out[i] = (rng.nextDouble() * 2 - 1) * noiseAmp;
  }
  for (var k = 0; k < syls.length; k++) {
    final s = syls[k];
    final prevEnd = k > 0 ? syls[k - 1].end : -1.0;
    final contiguous = (s.start - prevEnd).abs() < 0.005;
    if (s.unvoicedOnset) {
      // 60 ms of noise right before the vowel.
      final a = ((s.start - 0.06) * sr).round(), b = (s.start * sr).round();
      for (var i = math.max(0, a); i < math.min(n, b); i++) {
        out[i] += (rng.nextDouble() * 2 - 1) * 0.04;
      }
    }
    final a = (s.start * sr).round(), b = (s.end * sr).round();
    var phase = rng.nextDouble();
    for (var i = math.max(0, a); i < math.min(n, b); i++) {
      final t = (i - a) / sr;
      final dur = (b - a) / sr;
      var m = s.midi;
      if (s.glideTo != null) {
        final u = (t / dur).clamp(0.0, 1.0);
        final w = u < 0.4 ? 0.0 : u > 0.7 ? 1.0 : (u - 0.4) / 0.3;
        m = s.midi + (s.glideTo! - s.midi) * w;
      }
      if (t > 0.25) m += 0.25 * math.sin(2 * math.pi * 5.5 * t);
      final f0 = midiToHz(m);
      phase += f0 / sr;
      var env = 1.0;
      if (!contiguous || s.unvoicedOnset) {
        env = math.min(1.0, t / 0.02);
      } else {
        // voiced consonant: an 8 dB dip at the start
        env = t < 0.04 ? 0.4 + 0.6 * t / 0.04 : 1.0;
      }
      env *= math.min(1.0, (dur - t) / 0.03);
      var v = 0.0;
      for (var h = 1; h <= 10; h++) {
        v += math.sin(2 * math.pi * phase * h) / h;
      }
      out[i] += 0.25 * env * v;
    }
  }
  return out;
}
