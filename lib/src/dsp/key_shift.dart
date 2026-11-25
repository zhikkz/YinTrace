import 'dart:math' as math;
import 'dart:typed_data';

import 'real_fft.dart';
import 'resampler.dart';
import 'stft.dart';

/// Changes the pitch of mono or interleaved stereo PCM on the same timeline.
///
/// A phase-locked phase vocoder stretches time, then a centred polyphase
/// filter resamples by the reciprocal ratio. Analysis and synthesis are both
/// centred on frame zero. Each synthesis centre maps back to the input
/// independently, so rounding the hop cannot make the timeline drift.
Float32List shiftKey(
  Float32List input, {
  required int channels,
  required int sampleRate,
  required int semitones,
  void Function(double)? onProgress,
}) {
  if (semitones == 0 || input.isEmpty) return input;
  if ((channels != 1 && channels != 2) || input.length % channels != 0 || sampleRate <= 0) {
    throw ArgumentError('expected mono or stereo PCM at a positive sample rate');
  }
  RangeError.checkValueInInterval(semitones, -6, 6, 'semitones');
  // A small rational approximation keeps the polyphase filter compact.
  // The shift is within 1.2 cents of the requested frequency at any key.
  const rate = 1024;
  final stretchedRate = (rate * math.pow(2, semitones / 12)).round();
  final ratio = stretchedRate / rate;
  final frames = input.length ~/ channels;
  final length = (frames * ratio).ceil();
  final attacks = _attacks(input, channels, sampleRate);
  const n = 2048, half = n ~/ 2, hop = n ~/ 4, bins = half + 1;
  const turn = 2 * math.pi;
  final window = hannWindow(n);
  final output = _StretchOutput(
    PolyphaseResampler(stretchedRate, rate),
    length,
    Float32List(input.length),
    channels,
    window,
    hop,
  );
  final attackRadius = (half * math.max(1, ratio)).ceil();
  final fft = RealFft(n);
  final block = Float64List(n);
  var re = List.generate(channels, (_) => Float64List(bins));
  var im = List.generate(channels, (_) => Float64List(bins));
  var previousRe = List.generate(channels, (_) => Float64List(bins));
  var previousIm = List.generate(channels, (_) => Float64List(bins));
  final rotatedRe = Float64List(bins), rotatedIm = Float64List(bins);
  final rotation = Float64List(bins);
  final cosine = Float64List(bins), sine = Float64List(bins);
  final power = Float64List(bins);
  final peaks = Int32List(bins);
  var attackIndex = 0;
  var previousCenter = 0;
  for (var center = 0; center < length + half; center += hop) {
    var source = (center / ratio).round();
    while (attackIndex + 1 < attacks.length &&
        (attacks[attackIndex + 1] - source).abs() < (attacks[attackIndex] - source).abs()) {
      attackIndex++;
    }
    final attack = attacks.isEmpty ? -n : attacks[attackIndex];
    final anchor = (attack * ratio).round();
    // Read the short window around an attack at its original speed, with
    // the attack itself pinned to the stretched time. Resampling changes
    // its pitch, too, and puts the attack back at the original song time.
    final pinned = attack >= 0 && (anchor - center).abs() <= attackRadius;
    final reset = center == 0 || pinned;
    if (pinned) source = attack + center - anchor;
    for (var c = 0; c < channels; c++) {
      final base = source - half;
      final first = math.max(0, -base), end = math.min(n, frames - base);
      if (first > 0 || end < n) block.fillRange(0, n, 0);
      for (var i = first; i < end; i++) {
        block[i] = input[(base + i) * channels + c] * window[i];
      }
      fft.forward(block, re[c], im[c]);
      if (reset) output.addWindow(block, center, c);
    }
    final step = source - previousCenter;
    if (reset || step <= 0) {
      rotation.fillRange(0, bins, 0);
    } else {
      for (var k = 0; k < bins; k++) {
        var p = 0.0;
        for (var c = 0; c < channels; c++) {
          final a = re[c][k], b = im[c][k];
          p += a * a + b * b;
        }
        power[k] = p;
      }
      var count = 0;
      for (var k = 1; k < half; k++) {
        if (power[k] >= power[k - 1] && power[k] > power[k + 1]) peaks[count++] = k;
      }
      if (count == 0) peaks[count++] = 1;
      // Bins around a spectral peak share its phase correction. Use
      // the same complex rotation in both channels, preserving their
      // relative level and phase even for out-of-phase stereo.
      var first = 1;
      for (var p = 0; p < count; p++) {
        final k = peaks[p];
        var r = 0.0, i = 0.0;
        for (var c = 0; c < channels; c++) {
          final a = re[c][k], b = im[c][k], x = previousRe[c][k], y = previousIm[c][k];
          r += a * x + b * y;
          i += b * x - a * y;
        }
        final expected = turn * k * step / n;
        final error = math.atan2(i, r) - expected;
        final advance = expected + error - turn * (error / turn).round();
        var angle = rotation[k] + (hop / step - 1) * advance;
        angle -= turn * (angle / turn).round();
        final cs = math.cos(angle), sn = math.sin(angle);
        final end = p + 1 == count ? half : (k + peaks[p + 1]) ~/ 2 + 1;
        for (; first < end; first++) {
          rotation[first] = angle;
          cosine[first] = cs;
          sine[first] = sn;
        }
      }
    }
    if (!reset) {
      for (var c = 0; c < channels; c++) {
        final r = re[c], i = im[c];
        rotatedRe[0] = r[0];
        rotatedRe[half] = r[half];
        for (var k = 1; k < half; k++) {
          final cs = step <= 0 ? 1.0 : cosine[k], sn = step <= 0 ? 0.0 : sine[k];
          rotatedRe[k] = r[k] * cs - i[k] * sn;
          rotatedIm[k] = r[k] * sn + i[k] * cs;
        }
        fft.inverse(rotatedRe, rotatedIm, block);
        output.addWindow(block, center, c);
      }
    }
    output.emit(center + hop - half);
    (re, previousRe) = (previousRe, re);
    (im, previousIm) = (previousIm, im);
    previousCenter = source;
    if (center % (hop * 64) == 0) onProgress?.call(0.95 * center / (length + half));
  }
  final out = output.samples;
  var before = 0.0, after = 0.0, peak = 0.0;
  for (var i = 0; i < input.length; i++) {
    final a = input[i], b = out[i];
    before += a * a;
    after += b * b;
    peak = math.max(peak, b.abs());
  }
  if (after > 0) {
    final gain = math.min(math.sqrt(before / after), 0.9999 / peak);
    for (var i = 0; i < input.length; i++) {
      out[i] *= gain;
    }
  }
  onProgress?.call(1);
  return out;
}

/// Only windows still contributing to the next resampler taps are kept.
class _StretchOutput {
  _StretchOutput(this.filter, this.length, this.samples, this.channels, this.window, int hop)
    : _edgeGain = Float64List(window.length ~/ 2),
      _phases = List.generate(
        filter.up,
        (p) => Float64List.fromList([for (var k = p; k < filter.taps.length; k += filter.up) filter.taps[k]]),
      ) {
    final half = window.length ~/ 2;
    for (var f = 0; f < half; f++) {
      var sum = 0.0;
      for (var i = f + half; i >= 0; i -= hop) {
        sum += window[i] * window[i];
      }
      _edgeGain[f] = 1 / sum;
    }
  }

  final PolyphaseResampler filter;
  final int length, channels;
  final Float32List samples;
  final Float64List window, _edgeGain;
  final List<Float64List> _phases;
  // Larger than the FFT window and the polyphase filter's input support.
  static const _size = 4096, _mask = _size - 1;
  final _left = Float64List(_size), _right = Float64List(_size);
  int _normalized = 0, _cleared = 0, _out = 0;

  void addWindow(Float64List block, int center, int channel) {
    final ring = channel == 0 ? _left : _right;
    final base = center - window.length ~/ 2;
    final first = math.max(0, -base), stop = math.min(window.length, length - base);
    for (var i = first; i < stop; i++) {
      ring[(base + i) & _mask] += block[i] * window[i];
    }
  }

  void emit(int through) {
    final end = math.min(length, through);
    if (end <= _normalized) return;
    for (; _normalized < end; _normalized++) {
      final i = _normalized & _mask;
      // Four overlapping Hann windows have a constant sum of squares.
      final gain = _normalized < _edgeGain.length ? _edgeGain[_normalized] : 2 / 3;
      _left[i] *= gain;
      _right[i] *= gain;
    }
    final frames = samples.length ~/ channels;
    final up = filter.up, down = filter.down, half = filter.halfLen;
    final stereo = channels == 2;
    for (; _out < frames; _out++) {
      // Same zero-phase time origin as PolyphaseResampler.processChannel.
      final t = _out * down + half;
      final source = t ~/ up;
      if (source >= end && end < length) break;
      final taps = _phases[t % up];
      final first = math.max(0, source - length + 1);
      final stop = math.min(taps.length, source + 1);
      var left = 0.0, right = 0.0;
      if (stereo) {
        for (var k = first; k < stop; k++) {
          final i = (source - k) & _mask;
          final w = taps[k];
          left += _left[i] * w;
          right += _right[i] * w;
        }
        samples[2 * _out + 1] = right;
      } else {
        for (var k = first; k < stop; k++) {
          left += _left[(source - k) & _mask] * taps[k];
        }
      }
      samples[_out * channels] = left;
    }
    // Retain the FIR's look-behind for the next output sample.
    final keep = math.min(end, (_out * down - half) ~/ up);
    for (; _cleared < keep; _cleared++) {
      final i = _cleared & _mask;
      _left[i] = _right[i] = 0;
    }
  }
}

List<int> _attacks(Float32List input, int channels, int sampleRate) {
  final attacks = <int>[];
  final block = math.max(1, sampleRate ~/ 500);
  final frames = input.length ~/ channels;
  var floor = 0.0;
  for (var start = 0; start < frames; start += block) {
    final end = math.min(frames, start + block);
    var power = 0.0, peak = 0.0, at = start;
    for (var f = start; f < end; f++) {
      var energy = 0.0;
      for (var c = 0; c < channels; c++) {
        final v = input[f * channels + c];
        energy += v * v;
      }
      power += energy;
      if (energy > peak) {
        peak = energy;
        at = f;
      }
    }
    power /= (end - start) * channels;
    if (power > 0.00002 && power > 6 * floor && (attacks.isEmpty || at - attacks.last >= sampleRate ~/ 25)) {
      attacks.add(at);
    }
    floor += (power - floor) * (power > floor ? 0.23 : 0.06);
  }
  return attacks;
}
