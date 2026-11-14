import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/separation/mdx_separator.dart';
import 'package:yintrace/src/separation/model_config.dart';
import 'package:yintrace/src/separation/tensor_model.dart';
import 'package:yintrace/src/separation/vr_separator.dart';

import 'support/vr_configs.dart';

/// Produced by tools/reference/make_separation_fixtures.py from UVR's code.
final Map<String, dynamic> ref = jsonDecode(
  File('test/fixtures/separation_reference.json').readAsStringSync(),
);

const sr = 44100;

/// Same signal as `synth()` in the reference script (interleaved).
Float32List synth(double seconds) {
  final n = (seconds * sr).toInt();
  final out = Float32List(2 * n);
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final l =
        0.30 * math.sin(2 * math.pi * 220.0 * t) +
        0.20 * math.sin(2 * math.pi * 523.25 * t + 0.3) +
        0.10 * math.sin(2 * math.pi * 3100.0 * t) +
        0.05 * math.sin(2 * math.pi * 9000.0 * t + 1.1);
    final r =
        0.25 * math.sin(2 * math.pi * 330.0 * t + 0.7) +
        0.20 * math.sin(2 * math.pi * 523.25 * t) +
        0.08 * math.sin(2 * math.pi * 6200.0 * t);
    final env = 0.6 + 0.4 * math.sin(2 * math.pi * 0.5 * t);
    out[2 * i] = l * env;
    out[2 * i + 1] = r * env;
  }
  return out;
}

class FakeMdxModel implements TensorModel {
  int calls = 0;
  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    calls++;
    final f = shape[2], t = shape[3];
    final plane = f * t;
    final out = Float32List(input.length);
    for (var p = 0; p < 4; p++) {
      for (var b = 0; b < f; b++) {
        final g = 0.25 + 0.5 * (b % 7) / 6.0;
        for (var k = 0; k < t; k++) {
          final i = p * plane + b * t + k;
          out[i] = input[i] * g;
        }
      }
    }
    for (var i = 0; i < plane; i++) {
      out[i] += 0.1 * input[2 * plane + i];
      out[plane + i] += 0.1 * input[3 * plane + i];
    }
    return out;
  }

  @override
  Future<void> close() async {}
}

class FakeVrModel implements TensorModel {
  int calls = 0;
  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    calls++;
    final bins = shape[2], w = shape[3];
    final plane = bins * w;
    final out = Float32List(input.length);
    for (var b = 0; b < bins; b++) {
      for (var k = 0; k < w; k++) {
        final i = b * w + k;
        final x0 = input[i], x1 = input[plane + i];
        out[i] = 1 / (1 + math.exp(-(6 * x0 - 3 * x1 + 0.01 * b - 1)));
        out[plane + i] = 1 / (1 + math.exp(-(5 * x1 + 0.005 * b - 0.5)));
      }
    }
    return out;
  }

  @override
  Future<void> close() async {}
}

/// Unlike [FakeVrModel], the output depends on the whole window and on the
/// position in it, as a real network's does: a window that saw other frames
/// would give another mask.
class ContextVrModel implements TensorModel {
  int calls = 0;
  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    calls++;
    final bins = shape[2], w = shape[3];
    final plane = bins * w;
    final out = Float32List(input.length);
    for (var ch = 0; ch < 2; ch++) {
      for (var b = 0; b < bins; b++) {
        final row = ch * plane + b * w;
        var mean = 0.0;
        for (var k = 0; k < w; k++) {
          mean += input[row + k];
        }
        mean /= w;
        for (var k = 0; k < w; k++) {
          final other = input[(1 - ch) * plane + b * w + k];
          final z = 5 * input[row + k] - 8 * mean + 2 * other + 0.6 * k / w + 0.002 * b - 0.4;
          out[row + k] = 1 / (1 + math.exp(-z));
        }
      }
    }
    return out;
  }

  @override
  Future<void> close() async {}
}

void expectProbes(Float32List out, Map<String, dynamic> p, {double tol = 1e-4}) {
  final idx = (p['idx'] as List).cast<int>();
  final l = (p['l'] as List).cast<num>();
  final r = (p['r'] as List).cast<num>();
  var maxErr = 0.0;
  for (var k = 0; k < idx.length; k++) {
    final i = idx[k];
    if (i >= out.length ~/ 2) continue;
    maxErr = math.max(maxErr, (out[2 * i] - l[k]).abs());
    maxErr = math.max(maxErr, (out[2 * i + 1] - r[k]).abs());
  }
  var sum = 0.0;
  final n = math.min(out.length ~/ 2, p['len'] as int);
  for (var i = 0; i < 2 * n; i++) {
    sum += out[i] * out[i];
  }
  final rms = math.sqrt(sum / (2 * n));
  expect(maxErr, lessThan(tol), reason: 'max probe error');
  expect(rms, closeTo((p['rms'] as num).toDouble(), 1e-4));
}

void main() {
  final mix = synth(8.0);

  test('MDX demix matches UVR', () async {
    final model = FakeMdxModel();
    final sep = MdxSeparator(model, const MdxConfig());
    final progress = <double>[];
    final out = await sep.separate(mix, onProgress: progress.add);
    expect(out.length, mix.length);
    expect(model.calls, sep.chunkCount(mix.length ~/ 2));
    expect(progress.last, closeTo(1, 1e-9));
    expectProbes(out, ref['mdx'] as Map<String, dynamic>);
  });

  test('app MDX setting (T=128, overlap 0.25) matches UVR', () async {
    final model = FakeMdxModel();
    final sep = MdxSeparator(model, MdxConfig.vocFt);
    final out = await sep.separate(mix);
    expect(model.calls, sep.chunkCount(mix.length ~/ 2));
    expectProbes(out, ref['mdx_mobile'] as Map<String, dynamic>);
  });

  for (final cfg in [('4band_v2_sn', vr4BandV2Sn), ('3band_44100_msb2', VrConfig.karaoke6Hp)]) {
    test('VR ${cfg.$1} matches UVR (primary and secondary stems)', () async {
      final sep = VrSeparator(FakeVrModel(), cfg.$2);
      final y = await sep.separate(mix, stem: VrStem.primary);
      final v = await sep.separate(mix, stem: VrStem.secondary);
      // UVR's output length is hl*(frames-1); compare the common part.
      expectProbes(y, ref['vr_${cfg.$1}_primary'] as Map<String, dynamic>, tol: 2e-4);
      expectProbes(v, ref['vr_${cfg.$1}_secondary'] as Map<String, dynamic>, tol: 2e-4);
    });
  }

  // Segments sit on UVR's whole-song window grid: each window is inferred
  // once and sees the same frames, so segmenting must not change the result.
  for (final cfg in [
    ('4band_v2_sn', vr4BandV2Sn),
    ('3band_44100_msb2', VrConfig.karaoke6Hp),
    ('3band_44100_msb2, window 320', VrConfig.karaoke6Hp.withWindowSize(320)),
  ]) {
    test('VR ${cfg.$1}: segments reproduce whole-song processing, one run per window', () async {
      final long = synth(31.3);
      final whole = ContextVrModel();
      final single = await VrSeparator(whole, cfg.$2, segmentSeconds: 1000).separate(long);
      final probe = VrSeparator(whole, cfg.$2);
      expect(whole.calls, probe.inferenceCount(long.length ~/ 2));
      expect(probe.segmentCount(long.length ~/ 2), greaterThan(1));
      for (final seconds in [15.0, 4.0, 0.1]) {
        final model = ContextVrModel();
        final steps = <int>[];
        final seg = await VrSeparator(
          model,
          cfg.$2,
          segmentSeconds: seconds,
        ).separate(long, onStep: (done, total) => steps.add(done));
        expect(model.calls, whole.calls, reason: 'each window once ($seconds s segments)');
        expect(steps.last, whole.calls);
        var maxErr = 0.0, peak = 0.0;
        for (var i = 0; i < long.length; i++) {
          maxErr = math.max(maxErr, (single[i] - seg[i]).abs());
          peak = math.max(peak, single[i].abs());
        }
        expect(peak, greaterThan(0.05));
        expect(maxErr, lessThan(1e-5), reason: '$seconds s segments differ by $maxErr');
      }
    });
  }

  test('VR progress rises to 1 and the window count follows UVR', () async {
    final x = synth(9.0);
    final fractions = <double>[];
    final model = ContextVrModel();
    await VrSeparator(model, VrConfig.karaoke6Hp).separate(x, onProgress: fractions.add);
    expect(fractions.last, closeTo(1, 1e-9));
    for (var i = 1; i < fractions.length; i++) {
      expect(fractions[i], greaterThanOrEqualTo(fractions[i - 1]));
    }
    // UVR: windows = frames // roi + 1, minus a last one past the end.
    final sep = VrSeparator(model, VrConfig.karaoke6Hp);
    final frames = sep.spectrogramFrames(x.length ~/ 2);
    expect(model.calls, (frames - 1) ~/ 256 + 1);
    expect(VrSeparator(model, VrConfig.karaoke6Hp.withWindowSize(320)).inferenceCount(x.length ~/ 2), (frames - 1) ~/ 64 + 1);
  });
}
