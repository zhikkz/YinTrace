import 'dart:math' as math;
import 'dart:typed_data';

import 'real_fft.dart';

/// Result of analysing one frame.
class YinEstimate {
  const YinEstimate(this.frequency, this.aperiodicity, this.rms);

  /// Estimated fundamental frequency in Hz (0 when no candidate was found).
  final double frequency;

  /// Value of the cumulative mean normalised difference function at the
  /// chosen lag (0 = perfectly periodic, ~1 = noise).
  final double aperiodicity;

  /// RMS level of the analysed window.
  final double rms;

  bool isVoiced({double maxAperiodicity = 0.25, double minRms = 0.005}) =>
      frequency > 0 && aperiodicity <= maxAperiodicity && rms >= minRms;

  static const unvoiced = YinEstimate(0, 1, 0);
}

/// The YIN fundamental frequency estimator (de Cheveigné & Kawahara, 2002).
///
/// Each frame holds [frameSize] samples; the difference function integrates
/// over the first `frameSize - maxLag` samples. The difference function is
/// computed in O(N log N) with an FFT based cross-correlation.
class Yin {
  Yin({
    required this.sampleRate,
    this.frameSize = 2048,
    this.minFrequency = 60,
    this.maxFrequency = 1200,
    this.threshold = 0.15,
  })  : maxLag = math.min(frameSize ~/ 2, (sampleRate / minFrequency).ceil()),
        minLag = math.max(2, (sampleRate / maxFrequency).floor()) {
    window = frameSize - maxLag;
    var p = 1;
    while (p < frameSize + window) {
      p <<= 1;
    }
    _fftSize = p;
    _fft = RealFft(p);
    _a = Float64List(p);
    _b = Float64List(p);
    _ar = Float64List(p ~/ 2 + 1);
    _ai = Float64List(p ~/ 2 + 1);
    _br = Float64List(p ~/ 2 + 1);
    _bi = Float64List(p ~/ 2 + 1);
    _corr = Float64List(p);
    _diff = Float64List(maxLag + 2);
    _cmnd = Float64List(maxLag + 2);
    _energy = Float64List(frameSize + 1);
  }

  final int sampleRate;
  final int frameSize;
  final double minFrequency;
  final double maxFrequency;

  /// Absolute threshold of step 4 of the algorithm.
  final double threshold;
  final int maxLag;
  final int minLag;
  late final int window;

  late final int _fftSize;
  late final RealFft _fft;
  late final Float64List _a, _b, _ar, _ai, _br, _bi, _corr, _diff, _cmnd;
  late final Float64List _energy;

  /// The cumulative mean normalised difference of the last analysed frame.
  Float64List get lastCmnd => _cmnd;

  /// Analyses `samples[offset .. offset + frameSize)`.
  YinEstimate analyze(List<double> samples, [int offset = 0]) {
    final n = frameSize;
    if (offset < 0 || offset + n > samples.length) {
      throw RangeError('frame out of range');
    }
    final w = window;
    // Remove DC and copy.
    var mean = 0.0;
    for (var i = 0; i < n; i++) {
      mean += samples[offset + i];
    }
    mean /= n;
    var sumSq = 0.0;
    for (var i = 0; i < n; i++) {
      final v = samples[offset + i] - mean;
      _a[i] = v;
      sumSq += v * v;
    }
    final rms = math.sqrt(sumSq / n);
    if (rms < 1e-7) return YinEstimate(0, 1, rms);
    for (var i = n; i < _fftSize; i++) {
      _a[i] = 0;
    }
    for (var i = 0; i < w; i++) {
      _b[i] = _a[i];
    }
    for (var i = w; i < _fftSize; i++) {
      _b[i] = 0;
    }
    // corr[tau] = sum_{j<w} a[j] * a[j + tau]
    _fft.forward(_a, _ar, _ai);
    _fft.forward(_b, _br, _bi);
    final bins = _fftSize ~/ 2 + 1;
    for (var k = 0; k < bins; k++) {
      // A * conj(B)
      final ar = _ar[k], ai = _ai[k], br = _br[k], bi = _bi[k];
      _ar[k] = ar * br + ai * bi;
      _ai[k] = ai * br - ar * bi;
    }
    _fft.inverse(_ar, _ai, _corr);

    // Prefix sums of squares for the sliding energy term.
    _energy[0] = 0;
    for (var i = 0; i < n; i++) {
      _energy[i + 1] = _energy[i] + _a[i] * _a[i];
    }
    final e0 = _energy[w];
    final maxTau = maxLag;
    _diff[0] = 0;
    for (var tau = 1; tau <= maxTau; tau++) {
      final et = _energy[tau + w] - _energy[tau];
      final d = e0 + et - 2 * _corr[tau];
      _diff[tau] = d < 0 ? 0 : d;
    }
    // Cumulative mean normalised difference.
    _cmnd[0] = 1;
    var running = 0.0;
    for (var tau = 1; tau <= maxTau; tau++) {
      running += _diff[tau];
      _cmnd[tau] = running > 0 ? _diff[tau] * tau / running : 1;
    }
    // Absolute threshold.
    var best = -1;
    for (var tau = minLag; tau < maxTau; tau++) {
      if (_cmnd[tau] < threshold) {
        while (tau + 1 < maxTau && _cmnd[tau + 1] < _cmnd[tau]) {
          tau++;
        }
        best = tau;
        break;
      }
    }
    if (best < 0) {
      // No dip below the threshold: use the global minimum.
      var minV = double.infinity;
      for (var tau = minLag; tau < maxTau; tau++) {
        if (_cmnd[tau] < minV) {
          minV = _cmnd[tau];
          best = tau;
        }
      }
      if (best < 0) return YinEstimate(0, 1, rms);
    }
    // Parabolic interpolation.
    var refined = best.toDouble();
    if (best > 1 && best < maxTau) {
      final s0 = _cmnd[best - 1], s1 = _cmnd[best], s2 = _cmnd[best + 1];
      final denom = s0 - 2 * s1 + s2;
      if (denom.abs() > 1e-12) {
        final delta = 0.5 * (s0 - s2) / denom;
        if (delta.abs() < 1) refined = best + delta;
      }
    }
    return YinEstimate(sampleRate / refined, _cmnd[best], rms);
  }
}

/// Feeds arbitrary sized blocks and analyses frames at a fixed hop.
class StreamingYin {
  StreamingYin(this.yin, {required this.hop})
      : _buffer = Float64List(yin.frameSize * 4);

  final Yin yin;
  final int hop;
  final Float64List _buffer;
  int _filled = 0;
  int _consumed = 0; // total samples dropped from the front

  /// Absolute index (in samples pushed so far) of the first buffered sample.
  int get bufferStart => _consumed;

  /// Adds samples and returns estimates for every complete frame. Each
  /// result carries the absolute index of the frame centre.
  List<(int center, YinEstimate estimate)> push(List<double> samples) {
    final results = <(int, YinEstimate)>[];
    var i = 0;
    final n = yin.frameSize;
    while (i < samples.length) {
      final space = _buffer.length - _filled;
      final take = math.min(space, samples.length - i);
      for (var k = 0; k < take; k++) {
        _buffer[_filled + k] = samples[i + k];
      }
      _filled += take;
      i += take;
      var pos = 0;
      while (pos + n <= _filled) {
        results.add((_consumed + pos + n ~/ 2, yin.analyze(_buffer, pos)));
        pos += hop;
      }
      // Drop analysed hops.
      if (pos > 0) {
        _buffer.setRange(0, _filled - pos, _buffer, pos);
        _filled -= pos;
        _consumed += pos;
      }
    }
    return results;
  }

  void reset() {
    _filled = 0;
    _consumed = 0;
  }
}
