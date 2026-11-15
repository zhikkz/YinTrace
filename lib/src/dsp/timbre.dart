import 'dart:math' as math;
import 'dart:typed_data';

import 'real_fft.dart';

/// How fast the sound of the voice changes around each frame: the distance
/// between its spectral envelope (mel-frequency cepstral coefficients 1 to
/// [coeffs], so not the level) averaged over the [half] frames before and
/// the [half] frames after.
///
/// It rises where a new syllable changes the vowel or brings a consonant,
/// also when the voice is sung legato on one note, and stays low in the
/// middle of a held note. A big change of note moves the harmonics across
/// the bands and raises it too. Frame `f` is centred at `f * hop` in [x]
/// (sampled at [rate]), like the frames of `analyzePitch`.
Float32List spectralChange(List<double> x, int rate, int frames,
    {int hop = 128, int size = 1024, int bands = 26, int coeffs = 12, int half = 6}) {
  final fft = RealFft(size);
  final bins = fft.bins;
  final window = Float64List(size);
  for (var i = 0; i < size; i++) {
    window[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / size);
  }
  // Triangular mel filters from 80 Hz to 8 kHz.
  double toMel(double f) => 2595 * math.log(1 + f / 700) / math.ln10;
  double fromMel(double m) => 700 * (math.pow(10, m / 2595) - 1);
  final lo = toMel(80), hi = toMel(math.min(8000, rate / 2));
  final edges = [for (var i = 0; i < bands + 2; i++) fromMel(lo + (hi - lo) * i / (bands + 1)) * size / rate];
  final firstBin = Int32List(bands);
  final weights = <Float64List>[];
  for (var b = 0; b < bands; b++) {
    final a = edges[b], c = edges[b + 1], d = edges[b + 2];
    final k0 = a.ceil(), k1 = math.min(bins - 1, d.floor());
    firstBin[b] = k0;
    final w = Float64List(math.max(0, k1 - k0 + 1));
    for (var k = k0; k <= k1; k++) {
      w[k - k0] = k <= c ? (k - a) / math.max(1e-9, c - a) : (d - k) / math.max(1e-9, d - c);
    }
    weights.add(w);
  }
  final dct = Float64List(coeffs * bands);
  for (var c = 0; c < coeffs; c++) {
    for (var b = 0; b < bands; b++) {
      dct[c * bands + b] = math.cos(math.pi / bands * (b + 0.5) * (c + 1));
    }
  }
  // Running sums of the coefficients, for the averages before and after.
  final sums = Float64List((frames + 1) * coeffs);
  final buf = Float64List(size), re = Float64List(bins), im = Float64List(bins);
  final mel = Float64List(bands);
  final n = x.length;
  for (var f = 0; f < frames; f++) {
    final start = f * hop - size ~/ 2;
    for (var i = 0; i < size; i++) {
      final j = start + i;
      buf[i] = (j >= 0 && j < n ? x[j] : 0.0) * window[i];
    }
    fft.forward(buf, re, im);
    for (var b = 0; b < bands; b++) {
      var e = 0.0;
      final w = weights[b], k0 = firstBin[b];
      for (var k = 0; k < w.length; k++) {
        final r = re[k0 + k], q = im[k0 + k];
        e += w[k] * (r * r + q * q);
      }
      mel[b] = math.log(e + 1e-10);
    }
    for (var c = 0; c < coeffs; c++) {
      var s = 0.0;
      for (var b = 0; b < bands; b++) {
        s += dct[c * bands + b] * mel[b];
      }
      sums[(f + 1) * coeffs + c] = sums[f * coeffs + c] + s;
    }
  }
  final out = Float32List(frames);
  for (var j = half; j + half <= frames; j++) {
    var d = 0.0;
    for (var c = 0; c < coeffs; c++) {
      final before = (sums[j * coeffs + c] - sums[(j - half) * coeffs + c]) / half;
      final after = (sums[(j + half) * coeffs + c] - sums[j * coeffs + c]) / half;
      d += (after - before) * (after - before);
    }
    out[j] = math.sqrt(d);
  }
  return out;
}
