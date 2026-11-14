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
/// Long inputs are processed in overlapping segments so the memory use
/// stays bounded on phones; the magnitude normalisation uses the global
/// maximum (as UVR does for the whole file).
class VrSeparator {
  VrSeparator(
    this.model,
    this.config, {
    this.segmentSeconds = 12,
    this.marginSeconds = 3,
    this.crossfadeSeconds = 1,
  }) : _stfts = [for (final b in config.bands) Stft(nFft: b.nFft, hop: b.hl)];

  final TensorModel model;
  final VrConfig config;
  final double segmentSeconds;
  final double marginSeconds;
  final double crossfadeSeconds;
  final List<Stft> _stfts;

  int get _sr => config.bands.last.sr;

  /// Separates interleaved stereo PCM at the model rate (44.1 kHz).
  Future<Float32List> separate(
    Float32List stereo, {
    VrStem stem = VrStem.secondary,
    ProgressCallback? onProgress,
  }) async {
    final frames = stereo.length ~/ 2;
    final segs = _segments(frames);

    // Pass 1: global magnitude maximum.
    var coef = 0.0;
    for (final s in segs) {
      final x = _combined(_bandSpectrograms(_slice(stereo, s.$1, s.$2)));
      coef = math.max(coef, _maxMagnitude(x));
      onProgress?.call(0.1 * (s.$1 + s.$2) / (2 * frames));
    }
    if (coef <= 0) return Float32List(stereo.length);

    final out = Float32List(stereo.length);
    final weight = Float32List(frames);
    var segIndex = 0;
    for (final s in segs) {
      final start = s.$1, end = s.$2;
      final x = _combined(_bandSpectrograms(_slice(stereo, start, end)));
      final mask = await _inferMask(x, coef, (f) {
        onProgress?.call(0.1 + 0.9 * (segIndex + f) / segs.length);
      });
      _adjustAggressiveness(mask, x.frames);
      final y = _applyMask(x, mask, stem);
      final wave = _spectrogramToWave(y);
      _accumulate(out, weight, wave, s, frames);
      segIndex++;
      onProgress?.call(0.1 + 0.9 * segIndex / segs.length);
    }
    for (var i = 0; i < frames; i++) {
      final w = weight[i];
      if (w > 1e-6) {
        out[2 * i] /= w;
        out[2 * i + 1] /= w;
      }
    }
    return out;
  }

  // ---------------------------------------------------------------------
  // Segmentation
  // ---------------------------------------------------------------------

  /// Segments as (start, end, coreStart, coreEnd) in frames.
  List<(int, int, int, int)> _segments(int frames) {
    final sr = _sr;
    final core = (segmentSeconds * sr).round();
    final margin = (marginSeconds * sr).round();
    if (frames <= core + 2 * margin) return [(0, frames, 0, frames)];
    final out = <(int, int, int, int)>[];
    for (var c0 = 0; c0 < frames; c0 += core) {
      final c1 = math.min(frames, c0 + core);
      out.add((math.max(0, c0 - margin), math.min(frames, c1 + margin), c0, c1));
    }
    return out;
  }

  List<Float64List> _slice(Float32List stereo, int start, int end) {
    final n = end - start;
    final l = Float64List(n), r = Float64List(n);
    for (var i = 0; i < n; i++) {
      l[i] = stereo[2 * (start + i)];
      r[i] = stereo[2 * (start + i) + 1];
    }
    return [l, r];
  }

  void _accumulate(
    Float32List out,
    Float32List weight,
    List<Float64List> wave,
    (int, int, int, int) seg,
    int frames,
  ) {
    final (start, end, c0, c1) = seg;
    final fade = math.max(1, (crossfadeSeconds * _sr).round());
    final half = fade ~/ 2;
    final n = math.min(wave[0].length, end - start);
    for (var i = 0; i < n; i++) {
      final g = start + i;
      double w;
      if (c0 > 0 && g < c0 + half) {
        w = (g - (c0 - half)) / fade;
      } else if (c1 < frames && g >= c1 - half) {
        w = ((c1 + half) - g) / fade;
      } else {
        w = 1;
      }
      if (w <= 0) continue;
      if (w > 1) w = 1;
      out[2 * g] += wave[0][i] * w;
      out[2 * g + 1] += wave[1][i] * w;
      weight[g] += w;
    }
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

  static double _maxMagnitude(_StereoSpec s) {
    var m = 0.0;
    for (var ch = 0; ch < 2; ch++) {
      final re = s.re[ch], im = s.im[ch];
      for (var i = 0; i < re.length; i++) {
        final v = re[i] * re[i] + im[i] * im[i];
        if (v > m) m = v;
      }
    }
    return math.sqrt(m);
  }

  // ---------------------------------------------------------------------
  // inference_vr
  // ---------------------------------------------------------------------

  /// Returns the mask [2][bins+1][frames] (frequency-major per channel).
  Future<List<Float32List>> _inferMask(_StereoSpec x, double coef, void Function(double) progress) async {
    final c = config;
    final nBins = x.bins;
    final nFrame = x.frames;
    final window = c.windowSize;
    final offset = c.offset;
    var roi = window - offset * 2;
    if (roi == 0) roi = window;
    final padL = offset;
    final padR = roi - (nFrame % roi) + padL;
    final width = padL + nFrame + padR;
    final patches = (width - 2 * offset) ~/ roi;

    // Normalised magnitude, padded in time.
    final mag = [Float32List(nBins * width), Float32List(nBins * width)];
    final inv = 1.0 / coef;
    for (var ch = 0; ch < 2; ch++) {
      final re = x.re[ch], im = x.im[ch], m = mag[ch];
      for (var b = 0; b < nBins; b++) {
        final src = b * nFrame, dst = b * width + padL;
        for (var t = 0; t < nFrame; t++) {
          final r = re[src + t], i = im[src + t];
          m[dst + t] = math.sqrt(r * r + i * i) * inv;
        }
      }
    }

    final mask = [Float32List(nBins * nFrame), Float32List(nBins * nFrame)];
    final input = Float32List(2 * nBins * window);
    for (var p = 0; p < patches; p++) {
      final start = p * roi;
      for (var ch = 0; ch < 2; ch++) {
        final m = mag[ch];
        for (var b = 0; b < nBins; b++) {
          final src = b * width + start;
          input.setRange((ch * nBins + b) * window, (ch * nBins + b + 1) * window, m, src);
        }
      }
      final out = await model.run(input, [1, 2, nBins, window]);
      if (out.length != input.length) {
        throw StateError('VR model returned ${out.length} values, expected ${input.length}');
      }
      // predict_mask crops `offset` frames on both sides.
      for (var ch = 0; ch < 2; ch++) {
        for (var b = 0; b < nBins; b++) {
          final src = (ch * nBins + b) * window + offset;
          final dstBase = b * nFrame;
          for (var k = 0; k < roi; k++) {
            final t = start + k;
            if (t >= nFrame) break;
            mask[ch][dstBase + t] = out[src + k];
          }
        }
      }
      progress((p + 1) / patches);
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

  _StereoSpec _applyMask(_StereoSpec x, List<Float32List> mask, VrStem stem) {
    // The unmasked spectrogram is no longer needed after inference.
    // Reuse it instead of holding a second complex stereo spectrogram.
    final secondary = stem == VrStem.secondary;
    for (var ch = 0; ch < 2; ch++) {
      final m = mask[ch];
      for (var i = 0; i < m.length; i++) {
        final g = secondary ? 1 - m[i] : m[i];
        x.re[ch][i] *= g;
        x.im[ch][i] *= g;
      }
    }
    return x;
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
