import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/resampler.dart';
import '../dsp/stft.dart';
import 'model_config.dart';
import 'tensor_model.dart';

/// Which stem of a VR model to return.
enum VrStem {
  /// `mask * X` – the model's primary stem (e.g. "Instrumental" for the
  /// karaoke models, which then still contains the backing vocals).
  primary,

  /// `(1 - mask) * X` – the secondary stem (lead vocals for karaoke models).
  secondary,
}

/// Stereo complex spectrogram, frequency-major per channel.
class _StereoSpec {
  _StereoSpec(this.bins, this.frames)
    : re = [Float32List(bins * frames), Float32List(bins * frames)],
      im = [Float32List(bins * frames), Float32List(bins * frames)];

  final int bins;
  final int frames;
  final List<Float32List> re;
  final List<Float32List> im;
}

/// Port of UVR's VR-architecture inference (`SeperateVR`), including the
/// multi-band spectrogram helpers of `lib_v5/spec_utils.py`.
///
/// UVR computes one spectrogram of the whole song, normalises it by its
/// maximum and runs the network on windows of `windowSize` frames that
/// advance by `windowSize - 2 * offset` frames. A phone cannot hold a
/// whole-song spectrogram, so this port computes it in segments, but on the
/// same global window grid: every window is inferred exactly once and sees
/// exactly the frames it sees in UVR. Segments start on frame boundaries,
/// so every band's resampling and STFT line up with the whole-song ones;
/// the few frames the STFT and its inverse disturb at a segment's edges are
/// computed with extra context and dropped. The result equals whole-song
/// processing up to float rounding, without any crossfade.
class VrSeparator {
  VrSeparator(this.model, this.config, {this.segmentSeconds = 15})
    : _stfts = [for (final b in config.bands) Stft(nFft: b.nFft, hop: b.hl)] {
    final top = config.bands.last;
    for (final b in config.bands) {
      // Frame-aligned segments need every band to step by the same time.
      if (b.hl * top.sr != top.hl * b.sr) {
        throw ArgumentError('${config.name}: band hops are not aligned in time');
      }
    }
  }

  final TensorModel model;
  final VrConfig config;

  /// Audio whose mask one segment infers. Bounds the Dart working set (one
  /// segment's spectrograms); it does not change the result.
  final double segmentSeconds;
  final List<Stft> _stfts;

  int get _sr => config.bands.last.sr;

  /// Samples (at the model rate) between two spectrogram frames.
  int get _hop => config.bands.last.hl;

  /// Frames of mask each network window contributes.
  int get _roi {
    final roi = config.windowSize - 2 * config.offset;
    return roi == 0 ? config.windowSize : roi;
  }

  /// Frames next to a segment edge that the STFT padding, the resampling
  /// filters or the inverse STFT can disturb (with a safety margin).
  int get _edge {
    var frames = 0;
    for (final b in config.bands) {
      frames = math.max(frames, (b.nFft / (2 * b.hl)).ceil());
    }
    return frames + 4;
  }

  /// Frames of the combined spectrogram of [samples] input samples
  /// (UVR keeps the shortest band).
  int spectrogramFrames(int samples) {
    final bands = config.bands;
    var len = samples;
    var frames = -1;
    for (var d = bands.length - 1; d >= 0; d--) {
      if (d < bands.length - 1) {
        len = PolyphaseResampler(bands[d + 1].sr, bands[d].sr).outputLength(len);
      }
      final f = 1 + len ~/ bands[d].hl;
      frames = frames < 0 ? f : math.min(frames, f);
    }
    return frames;
  }

  /// Network runs needed for [samples] input samples: UVR's windows, minus a
  /// trailing one that would only cover padding.
  int inferenceCount(int samples) {
    if (samples < _hop) return 0;
    return (spectrogramFrames(samples) - 1) ~/ _roi + 1;
  }

  int _windowsPerSegment() => math.max(1, (segmentSeconds * _sr / _hop / _roi).round());

  /// Segments of [samples] input samples (each needs one spectrogram pass
  /// for the normalisation and one for the mask).
  int segmentCount(int samples) {
    final runs = inferenceCount(samples);
    final per = _windowsPerSegment();
    return (runs + per - 1) ~/ per;
  }

  /// Separates interleaved stereo PCM at the model rate (44.1 kHz).
  ///
  /// [onStep] reports finished network runs out of [inferenceCount].
  Future<Float32List> separate(
    Float32List stereo, {
    VrStem stem = VrStem.secondary,
    ProgressCallback? onProgress,
    void Function(int done, int total)? onStep,
  }) async {
    final n = stereo.length ~/ 2;
    final out = Float32List(stereo.length);
    final runs = inferenceCount(n);
    if (runs == 0) return out;
    final l = spectrogramFrames(n);
    final roi = _roi;
    final per = _windowsPerSegment();
    final segments = (runs + per - 1) ~/ per;
    final edge = _edge;
    // A normalisation pass over a segment costs about as much as a third of
    // a network run (measured on phones and desktops).
    const pass1Units = 0.3;
    final units = segments * pass1Units + runs;
    void progress(double done) => onProgress?.call(done / units);

    // Pass 1: UVR divides the magnitude by its maximum over the whole song.
    var coef = 0.0;
    for (var s = 0; s < segments; s++) {
      final a = s * per * roi, b = math.min((s + 1) * per * roi, l);
      final f0 = math.max(0, a - edge), f1 = math.min(l, b + edge);
      final x = _segmentSpectrogram(stereo, n, l, f0, f1);
      coef = math.max(coef, _maxMagnitude(x, a - f0, b - f0));
      progress((s + 1) * pass1Units);
    }
    if (coef <= 0) return out;

    // Pass 2: masks on UVR's window grid, then synthesis of each segment.
    final nBins = config.bins + 1;
    final input = Float32List(2 * nBins * config.windowSize);
    var cache = <int, List<Float32List>>{};
    var done = 0;
    onStep?.call(0, runs);
    for (var s = 0; s < segments; s++) {
      final a = s * per * roi, b = math.min((s + 1) * per * roi, l);
      // Mask frames whose inverse STFT reaches the output samples [a, b).
      final m0 = math.max(0, a - edge), m1 = math.min(l, b + edge);
      final k0 = m0 ~/ roi, k1 = (m1 - 1) ~/ roi;
      var first = k0; // first window not inferred by the previous segment
      while (first <= k1 && cache.containsKey(first)) {
        first++;
      }
      final f0 = math.max(0, math.min(m0, first * roi - config.offset) - edge);
      final f1 = math.min(l, math.max(m1, (k1 + 1) * roi + config.offset) + edge);
      final x = _segmentSpectrogram(stereo, n, l, f0, f1);

      final frames = m1 - m0;
      final mask = [Float32List(nBins * frames), Float32List(nBins * frames)];
      final keep = <int, List<Float32List>>{};
      for (var k = k0; k <= k1; k++) {
        var patch = cache[k];
        if (patch == null) {
          patch = await _inferWindow(x, f0, l, k, coef, input);
          done++;
          onStep?.call(done, runs);
          progress(segments * pass1Units + done);
        }
        // The window's mask covers frames [k*roi, (k+1)*roi).
        final t0 = math.max(m0, k * roi), t1 = math.min(m1, (k + 1) * roi);
        for (var ch = 0; ch < 2; ch++) {
          for (var bin = 0; bin < nBins; bin++) {
            mask[ch].setRange(
              bin * frames + t0 - m0,
              bin * frames + t1 - m0,
              patch[ch],
              bin * roi + t0 - k * roi,
            );
          }
        }
        if ((k + 1) * roi > b - edge) keep[k] = patch; // the next segment needs it
      }
      cache = keep;

      _adjustAggressiveness(mask, frames);
      final wave = _spectrogramToWave(_maskedFrames(x, m0 - f0, frames, mask, stem));
      // wave[i] is the sample m0*hop + i.
      final base = m0 * _hop;
      final end = b == l ? n : b * _hop;
      for (var i = a * _hop; i < end; i++) {
        final j = i - base;
        if (j >= wave[0].length) break;
        out[2 * i] = wave[0][j];
        out[2 * i + 1] = wave[1][j];
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Segments
  // ---------------------------------------------------------------------

  /// Combined spectrogram of frames [f0, f1) (more frames may follow).
  /// Frame `t` of the result is frame `f0 + t` of the whole-song one.
  _StereoSpec _segmentSpectrogram(Float32List stereo, int n, int l, int f0, int f1) {
    final start = f0 * _hop;
    // Up to the end of the song, the edge behaves exactly like UVR's.
    final end = f1 >= l ? n : math.min(n, f1 * _hop);
    final len = end - start;
    final left = Float64List(len), right = Float64List(len);
    for (var i = 0; i < len; i++) {
      left[i] = stereo[2 * (start + i)];
      right[i] = stereo[2 * (start + i) + 1];
    }
    return _combined(_bandSpectrograms([left, right]));
  }

  /// `X * mask` (primary) or `X * (1 - mask)` (secondary) for [frames]
  /// frames of [x] starting at [from].
  _StereoSpec _maskedFrames(_StereoSpec x, int from, int frames, List<Float32List> mask, VrStem stem) {
    final y = _StereoSpec(x.bins, frames);
    final secondary = stem == VrStem.secondary;
    for (var ch = 0; ch < 2; ch++) {
      final m = mask[ch], re = x.re[ch], im = x.im[ch], yr = y.re[ch], yi = y.im[ch];
      for (var bin = 0; bin < x.bins; bin++) {
        final src = bin * x.frames + from, dst = bin * frames;
        for (var t = 0; t < frames; t++) {
          final g = secondary ? 1 - m[dst + t] : m[dst + t];
          yr[dst + t] = re[src + t] * g;
          yi[dst + t] = im[src + t] * g;
        }
      }
    }
    return y;
  }

  // ---------------------------------------------------------------------
  // spec_utils.wave_to_spectrogram / combine_spectrograms
  // ---------------------------------------------------------------------

  List<_StereoSpec> _bandSpectrograms(List<Float64List> wave44) {
    final bands = config.bands;
    final n = bands.length;
    final waves = List<List<Float64List>?>.filled(n, null);
    final specs = List<_StereoSpec?>.filled(n, null);
    for (var d = n - 1; d >= 0; d--) {
      final bp = bands[d];
      if (d == n - 1) {
        waves[d] = wave44;
      } else {
        final upper = waves[d + 1]!;
        final fromSr = bands[d + 1].sr;
        waves[d] = [resample(upper[0], fromSr, bp.sr), resample(upper[1], fromSr, bp.sr)];
      }
      specs[d] = _waveToSpectrogram(waves[d]!, d);
      if (d < n - 1) waves[d + 1] = null; // free
    }
    return specs.cast<_StereoSpec>();
  }

  _StereoSpec _waveToSpectrogram(List<Float64List> wave, int band) {
    final c = config;
    var left = wave[0], right = wave[1];
    if (!c.isV51) {
      final n = left.length;
      if (c.reverse) {
        left = Float64List.fromList(left.reversed.toList());
        right = Float64List.fromList(right.reversed.toList());
      } else if (c.midSide) {
        final l = Float64List(n), r = Float64List(n);
        for (var i = 0; i < n; i++) {
          l[i] = (left[i] + right[i]) / 2;
          r[i] = left[i] - right[i];
        }
        left = l;
        right = r;
      } else if (c.midSideB2) {
        final l = Float64List(n), r = Float64List(n);
        for (var i = 0; i < n; i++) {
          l[i] = right[i] + left[i] * 0.5;
          r[i] = left[i] - right[i] * 0.5;
        }
        left = l;
        right = r;
      }
    }
    final stft = _stfts[band];
    final sl = stft.forward(left);
    final sr = stft.forward(right);
    final spec = _StereoSpec(sl.bins, sl.frames);
    spec.re[0].setAll(0, sl.re);
    spec.im[0].setAll(0, sl.im);
    spec.re[1].setAll(0, sr.re);
    spec.im[1].setAll(0, sr.im);
    if (c.isV51) _convertChannels(spec, c.bands[band].convertChannels);
    return spec;
  }

  static void _convertChannels(_StereoSpec s, String? cc) {
    if (cc == null) return;
    final n = s.re[0].length;
    for (final parts in [s.re, s.im]) {
      final a = parts[0], b = parts[1];
      for (var i = 0; i < n; i++) {
        final l = a[i], r = b[i];
        switch (cc) {
          case 'mid_side_c':
            a[i] = l + r * 0.25;
            b[i] = r - l * 0.25;
          case 'mid_side':
            a[i] = (l + r) / 2;
            b[i] = l - r;
          case 'stereo_n':
            a[i] = (l + r * 0.25) / 0.9375;
            b[i] = (r + l * 0.25) / 0.9375;
        }
      }
    }
  }

  _StereoSpec _combined(List<_StereoSpec> specs) {
    final c = config;
    final l = specs.map((s) => s.frames).reduce(math.min);
    final out = _StereoSpec(c.bins + 1, l);
    var offset = 0;
    for (var d = 0; d < c.bands.length; d++) {
      final bp = c.bands[d];
      final s = specs[d];
      final h = bp.cropStop - bp.cropStart;
      for (var ch = 0; ch < 2; ch++) {
        for (var k = 0; k < h; k++) {
          final src = (bp.cropStart + k) * s.frames;
          final dst = (offset + k) * l;
          for (var t = 0; t < l; t++) {
            out.re[ch][dst + t] = s.re[ch][src + t];
            out.im[ch][dst + t] = s.im[ch][src + t];
          }
        }
      }
      offset += h;
    }
    if (offset > c.bins) throw StateError('Too much bins');
    // Low-pass pre-filter.
    if (c.preFilterStart > 0) {
      if (c.isV51) {
        final mask = lpFilterMask(c.bins + 1, c.preFilterStart, c.preFilterStop);
        _scaleBins(out, mask);
      } else if (c.bands.length == 1) {
        _fftLpFilter(out, c.preFilterStart, c.preFilterStop);
      } else {
        var gp = 1.0;
        for (var b = c.preFilterStart + 1; b < c.preFilterStop; b++) {
          final g = math.pow(10, -(b - c.preFilterStart) * (3.5 - gp) / 20.0).toDouble();
          gp = g;
          _scaleBin(out, b, g);
        }
      }
    }
    return out;
  }

  /// Largest magnitude over frames [from, to).
  static double _maxMagnitude(_StereoSpec s, int from, int to) {
    var m = 0.0;
    for (var ch = 0; ch < 2; ch++) {
      final re = s.re[ch], im = s.im[ch];
      for (var bin = 0; bin < s.bins; bin++) {
        final base = bin * s.frames;
        for (var t = base + from; t < base + to; t++) {
          final v = re[t] * re[t] + im[t] * im[t];
          if (v > m) m = v;
        }
      }
    }
    return math.sqrt(m);
  }

  // ---------------------------------------------------------------------
  // inference_vr
  // ---------------------------------------------------------------------

  /// Runs the network on window [k] of UVR's grid and returns its mask
  /// `[2][bins+1][roi]` for frames `[k*roi, (k+1)*roi)`.
  ///
  /// UVR pads the magnitude with `offset` zero frames in front (and zeros
  /// after the end), so window k reads frames `[k*roi - offset, ...)`.
  /// [x] holds the frames starting at [f0]; [l] is the song's frame count.
  Future<List<Float32List>> _inferWindow(
    _StereoSpec x,
    int f0,
    int l,
    int k,
    double coef,
    Float32List input,
  ) async {
    final window = config.windowSize, offset = config.offset, roi = _roi;
    final nBins = x.bins;
    final start = k * roi - offset;
    final inv = 1.0 / coef;
    for (var ch = 0; ch < 2; ch++) {
      final re = x.re[ch], im = x.im[ch];
      for (var bin = 0; bin < nBins; bin++) {
        final dst = (ch * nBins + bin) * window;
        final src = bin * x.frames - f0;
        for (var t = 0; t < window; t++) {
          final f = start + t;
          if (f < 0 || f >= l) {
            input[dst + t] = 0;
          } else {
            final r = re[src + f], i = im[src + f];
            input[dst + t] = math.sqrt(r * r + i * i) * inv;
          }
        }
      }
    }
    final out = await model.run(input, [1, 2, nBins, window]);
    if (out.length != input.length) {
      throw StateError('VR model returned ${out.length} values, expected ${input.length}');
    }
    // predict_mask crops `offset` frames on both sides.
    final mask = [Float32List(nBins * roi), Float32List(nBins * roi)];
    for (var ch = 0; ch < 2; ch++) {
      for (var bin = 0; bin < nBins; bin++) {
        final src = (ch * nBins + bin) * window + offset;
        mask[ch].setRange(bin * roi, (bin + 1) * roi, out, src);
      }
    }
    return mask;
  }

  void _adjustAggressiveness(List<Float32List> mask, int frames) {
    final c = config;
    var aggr = c.aggression / 100.0 * 2;
    if (aggr == 0) return;
    if (c.primaryIsNonAccompaniment) aggr = 1 - aggr;
    final perCh = [aggr, aggr];
    final corr = c.aggrCorrection;
    if (corr != null) {
      perCh[0] += corr.$1;
      perCh[1] += corr.$2;
    }
    final split = c.bands.first.cropStop;
    final nBins = c.bins + 1;
    for (var ch = 0; ch < 2; ch++) {
      final low = 1 + perCh[ch] / 3, high = 1 + perCh[ch];
      final m = mask[ch];
      for (var b = 0; b < nBins; b++) {
        final e = b < split ? low : high;
        final base = b * frames;
        for (var t = 0; t < frames; t++) {
          final v = m[base + t];
          m[base + t] = v <= 0 ? 0 : math.pow(v, e).toDouble();
        }
      }
    }
  }

  // ---------------------------------------------------------------------
  // cmb_spectrogram_to_wave
  // ---------------------------------------------------------------------

  List<Float64List> _spectrogramToWave(_StereoSpec specM) {
    final c = config;
    final n = c.bands.length;
    final frames = specM.frames;
    var offset = 0;
    List<Float64List>? wave;
    for (var d = 0; d < n; d++) {
      final bp = c.bands[d];
      final nb = bp.nFft ~/ 2 + 1;
      final specS = _StereoSpec(nb, frames);
      final h = bp.cropStop - bp.cropStart;
      for (var ch = 0; ch < 2; ch++) {
        for (var k = 0; k < h; k++) {
          specS.re[ch].setRange(
            (bp.cropStart + k) * frames,
            (bp.cropStart + k + 1) * frames,
            specM.re[ch],
            (offset + k) * frames,
          );
          specS.im[ch].setRange(
            (bp.cropStart + k) * frames,
            (bp.cropStart + k + 1) * frames,
            specM.im[ch],
            (offset + k) * frames,
          );
        }
      }
      offset += h;
      if (d == n - 1) {
        if (bp.hpfStart > 0) _hpFilter(specS, bp.hpfStart, bp.hpfStop - 1);
        final w = _bandToWave(specS, d);
        wave = wave == null ? w : _add(wave, w);
      } else {
        final nextSr = c.bands[d + 1].sr;
        if (d == 0) {
          _lpFilter(specS, bp.lpfStart, bp.lpfStop);
          final w = _bandToWave(specS, d);
          wave = [resample(w[0], bp.sr, nextSr), resample(w[1], bp.sr, nextSr)];
        } else {
          _hpFilter(specS, bp.hpfStart, bp.hpfStop - 1);
          _lpFilter(specS, bp.lpfStart, bp.lpfStop);
          final w2 = _add(wave!, _bandToWave(specS, d));
          wave = [resample(w2[0], bp.sr, nextSr), resample(w2[1], bp.sr, nextSr)];
        }
      }
    }
    return wave!;
  }

  void _hpFilter(_StereoSpec s, int binStart, int binStop) {
    if (config.isV51) {
      _scaleBins(s, hpFilterMask(s.bins, binStart, binStop));
    } else {
      _fftHpFilter(s, binStart, binStop);
    }
  }

  void _lpFilter(_StereoSpec s, int binStart, int binStop) {
    if (config.isV51) {
      _scaleBins(s, lpFilterMask(s.bins, binStart, binStop));
    } else {
      _fftLpFilter(s, binStart, binStop);
    }
  }

  List<Float64List> _bandToWave(_StereoSpec s, int band) {
    final stft = _stfts[band];
    final l = stft.inverse(Spectrogram.from(s.bins, s.frames, s.re[0], s.im[0]));
    final r = stft.inverse(Spectrogram.from(s.bins, s.frames, s.re[1], s.im[1]));
    final c = config;
    final n = l.length;
    if (c.isV51) {
      final cc = c.bands[band].convertChannels;
      final a = Float64List(n), b = Float64List(n);
      switch (cc) {
        case 'mid_side_c':
          for (var i = 0; i < n; i++) {
            a[i] = l[i] / 1.0625 - r[i] / 4.25;
            b[i] = r[i] / 1.0625 + l[i] / 4.25;
          }
          return [a, b];
        case 'mid_side':
          for (var i = 0; i < n; i++) {
            a[i] = l[i] + r[i] / 2;
            b[i] = l[i] - r[i] / 2;
          }
          return [a, b];
        case 'stereo_n':
          for (var i = 0; i < n; i++) {
            a[i] = l[i] - r[i] * 0.25;
            b[i] = r[i] - l[i] * 0.25;
          }
          return [a, b];
      }
      return [l, r];
    }
    if (c.reverse) {
      return [Float64List.fromList(l.reversed.toList()), Float64List.fromList(r.reversed.toList())];
    }
    if (c.midSide) {
      final a = Float64List(n), b = Float64List(n);
      for (var i = 0; i < n; i++) {
        a[i] = l[i] + r[i] / 2;
        b[i] = l[i] - r[i] / 2;
      }
      return [a, b];
    }
    if (c.midSideB2) {
      final a = Float64List(n), b = Float64List(n);
      for (var i = 0; i < n; i++) {
        a[i] = r[i] / 1.25 + 0.4 * l[i];
        b[i] = l[i] / 1.25 - 0.4 * r[i];
      }
      return [a, b];
    }
    return [l, r];
  }

  static List<Float64List> _add(List<Float64List> a, List<Float64List> b) {
    final n = math.max(a[0].length, b[0].length);
    final out = [Float64List(n), Float64List(n)];
    for (var ch = 0; ch < 2; ch++) {
      for (var i = 0; i < a[ch].length; i++) {
        out[ch][i] += a[ch][i];
      }
      for (var i = 0; i < b[ch].length; i++) {
        out[ch][i] += b[ch][i];
      }
    }
    return out;
  }

  static void _scaleBin(_StereoSpec s, int bin, double g) {
    if (bin < 0 || bin >= s.bins) return;
    final base = bin * s.frames;
    for (var ch = 0; ch < 2; ch++) {
      for (var t = 0; t < s.frames; t++) {
        s.re[ch][base + t] *= g;
        s.im[ch][base + t] *= g;
      }
    }
  }

  static void _scaleBins(_StereoSpec s, Float64List mask) {
    for (var b = 0; b < s.bins; b++) {
      if (mask[b] != 1.0) _scaleBin(s, b, mask[b]);
    }
  }

  /// spec_utils.fft_lp_filter
  static void _fftLpFilter(_StereoSpec s, int binStart, int binStop) {
    var g = 1.0;
    for (var b = binStart; b < binStop; b++) {
      g -= 1 / (binStop - binStart);
      _scaleBin(s, b, g);
    }
    for (var b = math.max(0, binStop); b < s.bins; b++) {
      _scaleBin(s, b, 0);
    }
  }

  /// spec_utils.fft_hp_filter
  static void _fftHpFilter(_StereoSpec s, int binStart, int binStop) {
    var g = 1.0;
    for (var b = binStart; b > binStop; b--) {
      g -= 1 / (binStart - binStop);
      _scaleBin(s, b, g);
    }
    for (var b = 0; b <= binStop && b < s.bins; b++) {
      _scaleBin(s, b, 0);
    }
  }

  /// spec_utils.get_lp_filter_mask
  static Float64List lpFilterMask(int nBins, int binStart, int binStop) {
    final m = Float64List(nBins);
    var i = 0;
    for (; i < binStart - 1 && i < nBins; i++) {
      m[i] = 1;
    }
    final len = binStop - binStart + 1;
    for (var k = 0; k < len && i < nBins; k++, i++) {
      m[i] = len == 1 ? 1 : 1 - k / (len - 1);
    }
    return m; // the rest stays 0
  }

  /// spec_utils.get_hp_filter_mask
  static Float64List hpFilterMask(int nBins, int binStart, int binStop) {
    final m = Float64List(nBins);
    var i = binStop + 1; // zeros before
    final len = 1 + binStart - binStop;
    for (var k = 0; k < len && i < nBins; k++, i++) {
      m[i] = len == 1 ? 0 : k / (len - 1);
    }
    for (; i < nBins; i++) {
      m[i] = 1;
    }
    return m;
  }
}
