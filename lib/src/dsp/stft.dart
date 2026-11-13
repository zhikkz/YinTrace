import 'dart:math' as math;
import 'dart:typed_data';

import 'real_fft.dart';

enum PadMode { reflect, constant }

/// Periodic Hann window (`torch.hann_window(n, periodic=True)`,
/// `scipy.signal.get_window('hann', n)`).
Float64List hannWindow(int n) {
  final w = Float64List(n);
  for (var i = 0; i < n; i++) {
    w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / n);
  }
  return w;
}

/// A complex spectrogram stored frequency-major: index `bin * frames + t`.
class Spectrogram {
  Spectrogram(this.bins, this.frames)
      : re = Float32List(bins * frames),
        im = Float32List(bins * frames);

  Spectrogram.from(this.bins, this.frames, this.re, this.im)
      : assert(re.length == bins * frames && im.length == bins * frames);

  final int bins;
  final int frames;
  final Float32List re;
  final Float32List im;

  int index(int bin, int t) => bin * frames + t;
}

/// Short-time Fourier transform compatible with `torch.stft` /
/// `librosa.stft` (center=True, periodic Hann window, no normalisation) and
/// the matching inverse (`torch.istft` / `librosa.istft`).
class Stft {
  Stft({required this.nFft, required this.hop, this.padMode = PadMode.reflect})
      : window = hannWindow(nFft),
        _fft = RealFft(nFft),
        _frame = Float64List(nFft),
        _re = Float64List(nFft ~/ 2 + 1),
        _im = Float64List(nFft ~/ 2 + 1);

  final int nFft;
  final int hop;
  final PadMode padMode;
  final Float64List window;
  final RealFft _fft;
  final Float64List _frame;
  final Float64List _re;
  final Float64List _im;

  int get bins => nFft ~/ 2 + 1;

  int framesFor(int length) => 1 + length ~/ hop;

  /// Sample at index [i] of the centre-padded signal.
  static double _padded(List<double> x, int start, int length, int i, int pad,
      PadMode mode) {
    var j = i - pad;
    if (j >= 0 && j < length) return x[start + j];
    if (mode == PadMode.constant || length < 2) return 0.0;
    // Reflect (no edge repeat), folding as many times as needed.
    final period = 2 * (length - 1);
    j = j % period;
    if (j < 0) j += period;
    if (j >= length) j = period - j;
    return x[start + j];
  }

  /// Computes the STFT of `signal[start .. start+length)`.
  ///
  /// Only the first [maxBins] bins are kept (all when null).
  Spectrogram forward(List<double> signal,
      {int start = 0, int? length, int? maxBins}) {
    final len = length ?? signal.length - start;
    final frames = framesFor(len);
    final keep = math.min(maxBins ?? bins, bins);
    final out = Spectrogram(keep, frames);
    forwardInto(signal, out, start: start, length: len);
    return out;
  }

  /// Like [forward] but writes into an existing spectrogram starting at
  /// column [frameOffset]; `out.bins` bins are kept.
  void forwardInto(List<double> signal, Spectrogram out,
      {int start = 0, required int length, int frameOffset = 0}) {
    final frames = framesFor(length);
    final pad = nFft ~/ 2;
    final keep = out.bins;
    for (var t = 0; t < frames; t++) {
      final s0 = t * hop; // index in the padded signal
      final inner = s0 - pad;
      if (inner >= 0 && inner + nFft <= length) {
        final base = start + inner;
        for (var i = 0; i < nFft; i++) {
          _frame[i] = signal[base + i] * window[i];
        }
      } else {
        for (var i = 0; i < nFft; i++) {
          _frame[i] =
              _padded(signal, start, length, s0 + i, pad, padMode) * window[i];
        }
      }
      _fft.forward(_frame, _re, _im);
      final col = frameOffset + t;
      final stride = out.frames;
      for (var b = 0; b < keep; b++) {
        out.re[b * stride + col] = _re[b];
        out.im[b * stride + col] = _im[b];
      }
    }
  }

  /// Inverse STFT. Bins missing from [spec] (when it holds fewer than
  /// `nFft/2+1`) are treated as zero. Returns `hop * (frames - 1)` samples
  /// (the centre padding removed), or [length] samples when given.
  Float64List inverse(Spectrogram spec, {int? length}) {
    final frames = spec.frames;
    final pad = nFft ~/ 2;
    final total = nFft + hop * (frames - 1);
    final acc = Float64List(total);
    final env = Float64List(total);
    final have = math.min(spec.bins, bins);
    for (var t = 0; t < frames; t++) {
      for (var b = 0; b < have; b++) {
        _re[b] = spec.re[b * frames + t];
        _im[b] = spec.im[b * frames + t];
      }
      for (var b = have; b < bins; b++) {
        _re[b] = 0;
        _im[b] = 0;
      }
      _fft.inverse(_re, _im, _frame);
      final s0 = t * hop;
      for (var i = 0; i < nFft; i++) {
        final w = window[i];
        acc[s0 + i] += _frame[i] * w;
        env[s0 + i] += w * w;
      }
    }
    final outLen = length ?? hop * (frames - 1);
    final out = Float64List(outLen);
    final n = math.min(outLen, total - pad);
    for (var i = 0; i < n; i++) {
      final e = env[pad + i];
      out[i] = e > 1e-10 ? acc[pad + i] / e : 0.0;
    }
    return out;
  }
}
