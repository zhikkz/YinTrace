import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/dsp/real_fft.dart';
import 'package:yintrace/src/dsp/resampler.dart';
import 'package:yintrace/src/dsp/stft.dart';
import 'package:yintrace/src/dsp/yin.dart';

/// Reference values produced by tools/reference/make_dsp_fixtures.py.
final Map<String, dynamic> ref = jsonDecode(
    File('test/fixtures/dsp_reference.json').readAsStringSync());

List<double> _list(dynamic v) => (v as List).cast<num>().map((e) => e.toDouble()).toList();

Float64List _sine(double hz, int n, int sr, {double amp = 0.5, double phase = 0}) {
  final x = Float64List(n);
  for (var i = 0; i < n; i++) {
    x[i] = amp * math.sin(2 * math.pi * hz * i / sr + phase);
  }
  return x;
}

void main() {
  group('RealFft', () {
    for (final n in [16, 960, 7680]) {
      test('matches numpy.rfft for n=$n', () {
        final f = ref['rfft_$n'];
        final x = Float64List.fromList(_list(f['x']));
        final re = Float64List(n ~/ 2 + 1), im = Float64List(n ~/ 2 + 1);
        final fft = RealFft(n);
        fft.forward(x, re, im);
        final eRe = _list(f['re']), eIm = _list(f['im']);
        var maxErr = 0.0;
        for (var k = 0; k <= n ~/ 2; k++) {
          maxErr = math.max(maxErr, (re[k] - eRe[k]).abs());
          maxErr = math.max(maxErr, (im[k] - eIm[k]).abs());
        }
        expect(maxErr, lessThan(1e-8));
        final back = Float64List(n);
        fft.inverse(re, im, back);
        for (var i = 0; i < n; i++) {
          expect(back[i], closeTo(x[i], 1e-9));
        }
      });
    }
  });

  group('Stft', () {
    final sig = _list(ref['stft_signal']);
    for (final cfg in [(512, 128), (960, 480), (7680, 1024)]) {
      test('matches torch.stft/istft n_fft=${cfg.$1} hop=${cfg.$2}', () {
        final f = ref['stft_${cfg.$1}_${cfg.$2}'];
        final stft = Stft(nFft: cfg.$1, hop: cfg.$2);
        final spec = stft.forward(sig);
        expect(spec.bins, f['bins']);
        expect(spec.frames, f['frames']);
        for (final p in f['probe'] as List) {
          final b = p[0] as int, t = p[1] as int;
          expect(spec.re[spec.index(b, t)], closeTo((p[2] as num).toDouble(), 2e-3));
          expect(spec.im[spec.index(b, t)], closeTo((p[3] as num).toDouble(), 2e-3));
        }
        final y = stft.inverse(spec);
        expect(y.length, f['istft_len']);
        for (final p in f['istft_probe'] as List) {
          expect(y[p[0] as int], closeTo((p[1] as num).toDouble(), 1e-4));
        }
      });
    }

    test('matches librosa.stft with constant padding', () {
      final f = ref['librosa_640_432'];
      final spec = Stft(nFft: 640, hop: 432, padMode: PadMode.constant).forward(sig);
      expect(spec.frames, f['frames']);
      for (final p in f['probe'] as List) {
        final b = p[0] as int, t = p[1] as int;
        expect(spec.re[spec.index(b, t)], closeTo((p[2] as num).toDouble(), 2e-3));
        expect(spec.im[spec.index(b, t)], closeTo((p[3] as num).toDouble(), 2e-3));
      }
    });

    test('maxBins truncates and inverse zero-fills', () {
      final x = _sine(1000, 20000, 44100);
      final stft = Stft(nFft: 1024, hop: 256);
      final spec = stft.forward(x, maxBins: 400); // 1000 Hz ~ bin 23
      expect(spec.bins, 400);
      final y = stft.inverse(spec, length: x.length);
      for (var i = 2000; i < 18000; i += 997) {
        expect(y[i], closeTo(x[i], 1e-6));
      }
    });
  });

  group('PolyphaseResampler', () {
    final sig = _list(ref['resample_signal']);
    for (final r in [(44100, 22050), (44100, 14700), (7350, 14700), (22050, 44100), (44100, 48000)]) {
      test('matches scipy.resample_poly ${r.$1}->${r.$2}', () {
        final f = ref['resample_${r.$1}_${r.$2}'];
        final y = resample(sig, r.$1, r.$2);
        expect(y.length, f['len']);
        for (final p in f['probe'] as List) {
          expect(y[p[0] as int], closeTo((p[1] as num).toDouble(), 1e-9));
        }
      });
    }
  });

  group('Yin', () {
    test('detects pure tones across the vocal range', () {
      final yin = Yin(sampleRate: 44100);
      for (final hz in [82.41, 110.0, 196.0, 261.63, 440.0, 659.25, 987.77]) {
        final x = _sine(hz, 4096, 44100);
        final est = yin.analyze(x, 1000);
        expect(est.frequency, closeTo(hz, hz * 0.002), reason: '$hz Hz');
        expect(est.aperiodicity, lessThan(0.05));
        expect(est.isVoiced(), isTrue);
      }
    });

    test('handles a harmonic rich voice-like signal (missing fundamental energy)', () {
      const hz = 220.0;
      final n = 4096;
      final x = Float64List(n);
      for (var h = 1; h <= 8; h++) {
        final amp = h == 1 ? 0.05 : 0.4 / h;
        final s = _sine(hz * h, n, 44100, amp: amp, phase: h * 0.7);
        for (var i = 0; i < n; i++) {
          x[i] += s[i];
        }
      }
      final est = Yin(sampleRate: 44100).analyze(x, 512);
      expect(est.frequency, closeTo(hz, 1.0));
    });

    test('reports noise as unvoiced', () {
      final rng = math.Random(7);
      final x = Float64List.fromList(List.generate(4096, (_) => rng.nextDouble() * 2 - 1));
      final est = Yin(sampleRate: 44100).analyze(x, 0);
      expect(est.isVoiced(), isFalse);
      expect(Yin(sampleRate: 44100).analyze(Float64List(4096)).frequency, 0);
    });

    test('streaming analysis yields frames at the hop with correct centres', () {
      final yin = Yin(sampleRate: 16000, frameSize: 1024);
      final s = StreamingYin(yin, hop: 256);
      final x = _sine(300, 16000, 16000);
      final results = <(int, YinEstimate)>[];
      for (var i = 0; i < x.length; i += 333) {
        results.addAll(s.push(x.sublist(i, math.min(x.length, i + 333))));
      }
      expect(results.length, (16000 - 1024) ~/ 256 + 1);
      for (var i = 0; i < results.length; i++) {
        expect(results[i].$1, 512 + i * 256);
        expect(results[i].$2.frequency, closeTo(300, 1));
      }
    });
  });

  test('pitch helpers', () {
    expect(hzToMidi(440), closeTo(69, 1e-9));
    expect(midiToHz(60), closeTo(261.6256, 1e-3));
    expect(noteName(69), 'A4');
    expect(noteName(61), 'C♯4');
    expect(pitchClassDistance(72.3, 60), closeTo(0.3, 1e-9));
    expect(pitchClassDistance(59.0, 60), closeTo(-1, 1e-9));
    expect(median([3, 1, 2]), 2);
  });
}
