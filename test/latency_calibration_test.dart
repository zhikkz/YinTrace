import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/practice/latency_calibration.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

Float32List _record(LatencyCalibrationSignal signal, double Function(int frame, Float32List output) mic) {
  final engine = PracticeEngine.create(sampleRate: signal.sampleRate, mode: EngineMode.offline);
  try {
    engine.loadTrackPcm(0, signal.pcm, 1);
    engine.start();
    engine.play();
    final capture = LatencyCalibrationCapture(signal.pcm.length);
    final output = Float32List(signal.pcm.length);
    // Even a 3 ms delay is longer than one block, so its samples come from
    // previous render calls. Use the engine's actual output as the source.
    for (var start = 0; start < output.length; start += 127) {
      final length = math.min(127, output.length - start);
      final input = Float32List(length);
      for (var i = 0; i < length; i++) {
        input[i] = mic(start + i, output);
      }
      final stereo = engine.render(length, input: input);
      for (var i = 0; i < length; i++) {
        output[start + i] = stereo[2 * i];
      }
      for (final block in engine.readCapture()) {
        capture.add(block);
      }
    }
    expect(capture.complete, isTrue);
    return capture.samples;
  } finally {
    engine.dispose();
  }
}

double _at(Float32List samples, int index) => index < 0 ? 0 : samples[index];

void main() {
  final noNative = Platform.environment['YINTRACE_AUDIO_LIB']?.isNotEmpty != true;

  group('automatic latency calibration', () {
    for (final (delayMs, rate) in [(3, 44100), (27, 48000), (95, 44100), (186, 44100), (400, 44100)]) {
      test('recovers $delayMs ms with quiet loopback at $rate Hz', () {
        final signal = LatencyCalibrationSignal(LatencyCalibrationMethod.automatic, rate);
        final lag = (delayMs * rate / 1000).round();
        final slap = (0.0063 * rate).round();
        final tail = (0.017 * rate).round();
        final rng = math.Random(delayMs);
        final samples = _record(signal, (frame, out) {
          final direct = _at(out, frame - lag);
          final echo = 0.24 * _at(out, frame - lag - slap) - 0.11 * _at(out, frame - lag - tail);
          // Peak 0.24 becomes 0.0076 after -30 dB. White noise RMS is
          // about a third of the attenuated chirp RMS (10 dB active SNR).
          final noise = (2 * rng.nextDouble() - 1) * 0.0018;
          return (direct + echo) * 0.03162 + noise;
        });
        expect(signal.estimateSeconds(samples) * 1000, closeTo(delayMs, 1));
      }, skip: noNative);
    }

    test('reports no test sound when the microphone only hears noise', () {
      final signal = LatencyCalibrationSignal(LatencyCalibrationMethod.automatic, 44100);
      final rng = math.Random(48);
      final samples = _record(signal, (_, _) => (2 * rng.nextDouble() - 1) * 0.0018);
      expect(() => signal.estimateSeconds(samples), throwsA(LatencyCalibrationFailure.noTestSound));
    }, skip: noNative);

    test('rejects six audible pulses with inconsistent delays', () {
      const rate = 44100;
      final signal = LatencyCalibrationSignal(LatencyCalibrationMethod.automatic, rate);
      final samples = _record(signal, (frame, out) {
        final delay = frame < signal.cueFrames[3] ? 0.12 : 0.16;
        return 0.03 * _at(out, frame - (delay * rate).round());
      });
      expect(() => signal.estimateSeconds(samples), throwsA(LatencyCalibrationFailure.inconsistentTestSound));
    }, skip: noNative);
  });

  group('tap-along latency calibration', () {
    const rate = 44100;
    const delayMs = 247;
    final signal = LatencyCalibrationSignal(LatencyCalibrationMethod.tapAlong, rate);

    Float32List recordTaps(List<double> jitterMs) {
      final rng = math.Random(8);
      final taps = [
        for (var i = 0; i < jitterMs.length; i++)
          signal.cueFrames[3 + i] + ((delayMs + jitterMs[i]) * rate / 1000).round(),
      ];
      var current = 0;
      return _record(signal, (frame, out) {
        final noise = 0.003 * (2 * rng.nextDouble() - 1) + 0.004 * math.sin(2 * math.pi * 60 * frame / rate);
        final leak = 0.05 * _at(out, frame - (0.21 * rate).round());
        if (current + 1 < taps.length && frame >= taps[current + 1]) current++;
        final age = (frame - taps[current]) / rate;
        if (age < 0 || age > 0.08) return noise + leak;
        final envelope = (1 - math.exp(-age / 0.0013)) * math.exp(-age / 0.020);
        final tap =
            0.045 * math.sin(2 * math.pi * 240 * age) +
            0.048 * math.sin(2 * math.pi * 1870 * age) +
            0.032 * math.sin(2 * math.pi * 3800 * age);
        return noise + leak + envelope * tap;
      });
    }

    test('recovers the latency with noise and randomized ±15 ms timing', () {
      final rng = math.Random(71);
      final jitter = <double>[
        for (var i = 0; i < 5; i++) ...[rng.nextDouble() * 15, -rng.nextDouble() * 15],
      ]..shuffle(rng);
      // The first two attempts can be far off while the singer gets ready.
      final samples = recordTaps([130, -150, ...jitter]);
      expect(signal.estimateSeconds(samples) * 1000, closeTo(delayMs, 5));
    }, skip: noNative);

    test('drops a single early or late response', () {
      final samples = recordTaps([0, 0, -9, 4, 6, -3, 210, 0, 5, -10, 7, -2]);
      expect(signal.estimateSeconds(samples) * 1000, closeTo(delayMs, 5));
    }, skip: noNative);

    test('rejects responses that drift and jump around the beat', () {
      final samples = recordTaps([0, 0, -132, 210, -54, 281, 35, -120, 104, -81, 120, -23]);
      expect(() => signal.estimateSeconds(samples), throwsA(LatencyCalibrationFailure.unsteadyBeat));
    }, skip: noNative);

    test('does not count leaked headphone cues as taps', () {
      final rng = math.Random(19);
      final samples = _record(
        signal,
        (frame, out) => 0.55 * _at(out, frame - 8400) + 0.0002 * (2 * rng.nextDouble() - 1),
      );
      expect(() => signal.estimateSeconds(samples), throwsA(LatencyCalibrationFailure.unsteadyBeat));
    }, skip: noNative);
  });

  test('capture ignores paused blocks and rejects a gap in the song frames', () {
    final capture = LatencyCalibrationCapture(6);
    final samples = Float32List.fromList([0.1, 0.2]);
    capture.add(CaptureBlock(samples, 0, 200, false));
    capture.add(CaptureBlock(samples, 0, 202, true));
    expect(() => capture.add(CaptureBlock(samples, 4, 204, true)), throwsA(LatencyCalibrationFailure.audioUnavailable));
    expect(capture.complete, isFalse);
  });
}
