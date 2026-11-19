import 'dart:math' as math;
import 'dart:typed_data';

import '../separation/tensor_model.dart';

/// Pitch and confidence of consecutive SwiftF0 frames.
class SwiftF0Frames {
  SwiftF0Frames(this.hz, this.confidence, [this.bins])
    : assert(hz.length == confidence.length && (bins == null || bins.length == hz.length * SwiftF0.bins));

  /// Pitch in Hz; frame `i` is centred at input sample `i * SwiftF0.hop`.
  final Float32List hz;

  /// How sure the model is that the frame is voiced and its pitch right
  /// (0..1); voiced at [SwiftF0.voicedConfidence] or above.
  final Float32List confidence;

  /// The model's score (logit) for each of its [SwiftF0.bins] pitch bins,
  /// frame by frame: bin `b` of frame `i` at `i * SwiftF0.bins + b`. The
  /// pitch is taken from the best bin in range; the other bins say which
  /// other pitches the model heard (the octave below, a second voice).
  /// Null for a model that does not give them.
  final Float32List? bins;

  int get length => hz.length;
}

/// SwiftF0 (Lars Nieradzik, 2025; MIT): a convolutional network of 14 386
/// parameters that reads the pitch from a spectrogram of 16 kHz audio. For
/// every 16 ms frame it gives a pitch and a confidence that the frame is
/// voiced and the pitch right. Unlike YIN it was trained on speech and
/// music with noise, other music and rooms mixed in, so it tells a voice
/// from what surrounds it instead of following thresholds on periodicity.
///
/// The app bundles the official model of swift-f0 0.3.0 with its search
/// range fixed at [minHz]..[maxHz] and its two outputs joined into one
/// `[2, frames]` tensor (pitch, confidence); `tools/build_pitch_model.py`
/// builds it and checks that it computes exactly what the original does.
class SwiftF0 {
  SwiftF0(this.model);

  final TensorModel model;

  static const sampleRate = 16000;
  static const hop = 256;
  static const frameSeconds = hop / sampleRate;

  /// The range the bundled model searches (see the build script); frames
  /// whose best pitch lies outside it are unvoiced.
  static const minHz = 60.0;
  static const maxHz = 1400.0;

  /// The model's confidence is calibrated for this voicing threshold.
  static const voicedConfidence = 0.5;

  /// The model classifies the pitch into this many bins, spaced evenly in
  /// log frequency from [binMinHz] to [binMaxHz] (about 70 cents apart).
  static const bins = 95;
  static const binMinHz = 46.875;
  static const binMaxHz = 2093.75;

  /// The frequency of bin [b].
  static double binHz(num b) => binMinHz * math.pow(binMaxHz / binMinHz, b / (bins - 1));

  /// The model hears 2815 samples on each side of a frame: a frame comes
  /// out as in one run over the whole recording when the run holds
  /// [history] frames before it and [lookahead] frames after it.
  static const history = 11;
  static const lookahead = 10;

  /// Frames per model run over a long recording (30 s): bounds the memory.
  static const runFrames = 1875;

  /// A frame of digital silence is unvoiced. The model never heard one
  /// (its spectrogram sits on the log floor in every bin) and answers it
  /// with random voiced frames.
  static const silencePeak = 1e-3;

  /// Frames for [audio] (16 kHz): `max(1, audio.length ~/ hop)` of them.
  ///
  /// The bundled model gives `[2 + bins, frames]` (pitch, confidence, bin
  /// scores); a model that gives only `[2, frames]` leaves out the bins.
  Future<SwiftF0Frames> run(Float32List audio) async {
    final n = math.max(1, audio.length ~/ hop);
    final out = await model.run(audio, [1, audio.length]);
    if (out.length != 2 * n && out.length != (2 + bins) * n) {
      throw StateError('pitch model returned ${out.length} values for $n frames');
    }
    final hz = Float32List.fromList(Float32List.sublistView(out, 0, n));
    final confidence = Float32List.fromList(Float32List.sublistView(out, n, 2 * n));
    Float32List? scores;
    if (out.length > 2 * n) {
      // Rows of bins -> frames of bins.
      scores = Float32List(n * bins);
      for (var b = 0; b < bins; b++) {
        final row = (2 + b) * n;
        for (var i = 0; i < n; i++) {
          final v = out[row + i];
          scores[i * bins + b] = v.isFinite ? v : -1e4;
        }
      }
    }
    for (var i = 0; i < n; i++) {
      final a = audio.length >= hop ? i * hop : 0;
      final b = audio.length >= hop ? a + hop : audio.length;
      var peak = 0.0;
      for (var k = a; k < b; k++) {
        final v = audio[k].abs();
        if (v > peak) peak = v;
      }
      if (peak < silencePeak || !hz[i].isFinite || !confidence[i].isFinite) confidence[i] = 0;
    }
    return SwiftF0Frames(hz, confidence, scores);
  }

  /// A whole recording (16 kHz), in runs of [runFrames] frames with the
  /// context that makes them come out as one run over all of it would.
  /// [onProgress] gets the fraction done after each run.
  Future<SwiftF0Frames> analyze(Float32List audio, {void Function(double fraction)? onProgress}) async {
    final n = math.max(1, audio.length ~/ hop);
    final hz = Float32List(n), confidence = Float32List(n);
    Float32List? scores;
    var withBins = true;
    for (var start = 0; start < n; start += runFrames) {
      final end = math.min(start + runFrames, n);
      final left = math.max(0, start - history);
      final to = end < n ? math.min(audio.length, (end + lookahead) * hop) : audio.length;
      final frames = await run(Float32List.sublistView(audio, left * hop, to));
      hz.setRange(start, end, frames.hz, start - left);
      confidence.setRange(start, end, frames.confidence, start - left);
      final b = frames.bins;
      if (b == null) {
        withBins = false;
      } else if (withBins) {
        scores ??= Float32List(n * bins);
        scores.setRange(start * bins, end * bins, b, (start - left) * bins);
      }
      onProgress?.call(end / n);
    }
    return SwiftF0Frames(hz, confidence, withBins ? scores : null);
  }
}
