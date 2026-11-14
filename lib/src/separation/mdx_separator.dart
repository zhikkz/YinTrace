import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/stft.dart';
import 'model_config.dart';
import 'tensor_model.dart';

/// Port of UVR's MDX-Net demixing (`SeperateMDX.demix` / `run_model`).
///
/// Input and output are interleaved stereo float PCM at 44.1 kHz.
class MdxSeparator {
  MdxSeparator(this.model, this.config) : _stft = Stft(nFft: config.nFft, hop: config.hop);

  final TensorModel model;
  final MdxConfig config;
  final Stft _stft;

  /// Number of model invocations needed for [frames] input frames.
  int chunkCount(int frames) {
    final c = config;
    final genSize = c.chunkSize - 2 * c.trim;
    final pad = genSize + c.trim - (frames % genSize);
    final total = c.trim + frames + pad;
    return (total + _step - 1) ~/ _step;
  }

  int get _step {
    final c = config;
    // Negative overlap selects UVR's "Default" (step = chunk - n_fft).
    if (c.overlap < 0) return c.chunkSize - c.nFft;
    if (c.overlap == 0) return c.chunkSize;
    return math.max(1, ((1 - c.overlap) * c.chunkSize).toInt());
  }

  /// Separates the model's primary stem (Vocals for Voc_FT), scaled by the
  /// model's `compensate` factor exactly like UVR.
  Future<Float32List> separate(Float32List stereo, {ProgressCallback? onProgress}) async {
    final c = config;
    final frames = stereo.length ~/ 2;
    final chunk = c.chunkSize;
    final trim = c.trim;
    final genSize = chunk - 2 * trim;
    final pad = genSize + trim - (frames % genSize);
    final total = trim + frames + pad;

    // The padded mixture is `trim` zeros + input + `pad` zeros; it is read
    // straight from [stereo] to keep memory low on phones.
    // Only the unfinalized overlap needs accumulation. Once the next chunk
    // starts, earlier samples cannot change. Keep one chunk in a ring instead
    // of three song-length arrays (159 MB for a five-minute song).
    final result = Float32List(chunk * 2);
    final divider = Float32List(chunk);
    final output = Float32List(frames * 2);
    var finalized = 0;

    final step = _step;
    final nChunks = (total + step - 1) ~/ step;
    final useWindow = c.overlap != 0;
    final part = Float64List(chunk);
    final input = Float32List(4 * c.dimF * c.dimT);
    final planeSize = c.dimF * c.dimT;
    var done = 0;

    for (var start = 0; start < total; start += step) {
      final end = math.min(start + chunk, total);
      final actual = end - start;
      // Build the [1, 4, dimF, dimT] spectrogram tensor: L.re, L.im, R.re, R.im
      for (var ch = 0; ch < 2; ch++) {
        for (var i = 0; i < chunk; i++) {
          final j = start + i - trim;
          part[i] = (i < actual && j >= 0 && j < frames) ? stereo[2 * j + ch] : 0.0;
        }
        final spec = _stft.forward(part, maxBins: c.dimF);
        assert(spec.frames == c.dimT, 'chunk/frames mismatch');
        input.setRange(2 * ch * planeSize, (2 * ch + 1) * planeSize, spec.re);
        input.setRange((2 * ch + 1) * planeSize, (2 * ch + 2) * planeSize, spec.im);
      }
      // spek[:, :, :3, :] *= 0
      for (var p = 0; p < 4; p++) {
        input.fillRange(p * planeSize, p * planeSize + 3 * c.dimT, 0);
      }

      final out = await model.run(input, c.inputShape);
      if (out.length != input.length) {
        throw StateError('MDX model returned ${out.length} values, expected ${input.length}');
      }

      final window = useWindow ? _hanning(actual) : null;
      for (var ch = 0; ch < 2; ch++) {
        final re = Float32List.sublistView(out, 2 * ch * planeSize, (2 * ch + 1) * planeSize);
        final im = Float32List.sublistView(out, (2 * ch + 1) * planeSize, (2 * ch + 2) * planeSize);
        final wave = _stft.inverse(Spectrogram.from(c.dimF, c.dimT, re, im), length: chunk);
        if (window != null) {
          for (var i = 0; i < actual; i++) {
            result[2 * ((start + i) % chunk) + ch] += wave[i] * window[i];
          }
        } else {
          for (var i = 0; i < actual; i++) {
            result[2 * ((start + i) % chunk) + ch] += wave[i];
          }
        }
      }
      if (window != null) {
        for (var i = 0; i < actual; i++) {
          divider[(start + i) % chunk] += window[i];
        }
      } else {
        for (var i = 0; i < actual; i++) {
          divider[(start + i) % chunk] += 1;
        }
      }
      final until = math.min(start + step, total);
      for (; finalized < until; finalized++) {
        final slot = finalized % chunk;
        final i = finalized - trim;
        final d = divider[slot];
        if (i >= 0 && i < frames && d > 1e-8) {
          output[2 * i] = result[2 * slot] / d * c.compensate;
          output[2 * i + 1] = result[2 * slot + 1] / d * c.compensate;
        }
        result[2 * slot] = 0;
        result[2 * slot + 1] = 0;
        divider[slot] = 0;
      }
      done++;
      onProgress?.call(done / nChunks);
    }

    return output;
  }

  /// `numpy.hanning` (symmetric).
  static Float64List _hanning(int m) {
    final w = Float64List(m);
    if (m == 1) {
      w[0] = 1;
      return w;
    }
    for (var i = 0; i < m; i++) {
      w[i] = 0.5 - 0.5 * math.cos(2 * math.pi * i / (m - 1));
    }
    return w;
  }

  /// UVR's secondary stem: `mix - primary` (primary already compensated).
  static Float32List secondaryStem(Float32List mix, Float32List primary) {
    final out = Float32List(mix.length);
    for (var i = 0; i < mix.length; i++) {
      out[i] = mix[i] - primary[i];
    }
    return out;
  }
}
