import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/dsp/key_shift.dart';
import 'package:yintrace/src/dsp/pitch.dart';

const _sr = 44100;

void main() {
  test('the original key returns the original samples and length exactly', () {
    final x = Float32List.fromList([0.7, -0.6, 0, 0.000003, -0.157, 0.9]);
    expect(shiftKey(x, channels: 2, sampleRate: _sr, semitones: 0), same(x));
  });

  test('every available semitone shift is within 3 cents and keeps the frame count', () {
    for (final midi in [45.0, 69.0, 83.0]) {
      final hz = midiToHz(midi);
      final x = Float32List.fromList([
        for (var i = 0; i < _sr + 173; i++) 0.48 * math.sin(2 * math.pi * hz * i / _sr),
      ]);
      for (var key = -6; key <= 6; key++) {
        final y = shiftKey(x, channels: 1, sampleRate: _sr, semitones: key);
        final measured = hzToMidi(_frequency(y));
        expect(y.length, x.length);
        expect((measured - midi - key).abs() * 100, lessThanOrEqualTo(3), reason: 'MIDI $midi, key $key');
        _expectLevel(x, y);
      }
    }
  });

  test('stereo clicks keep their position, including the first frame', () {
    const clicks = [0, 4911, 9947, 15205, 20303, 28858, 37177, _sr - 272];
    final x = Float32List(2 * _sr);
    for (final (i, frame) in clicks.indexed) {
      x[2 * frame] = i.isEven ? 0.55 : -0.42;
      x[2 * frame + 1] = -0.4 * x[2 * frame];
    }
    for (final key in [-6, -3, 2, 6]) {
      final y = shiftKey(x, channels: 2, sampleRate: _sr, semitones: key);
      expect(y.length, x.length);
      for (final click in clicks) {
        var peak = math.max(0, click - 1100);
        for (var f = peak + 1; f < math.min(_sr, click + 1100); f++) {
          if (y[2 * f].abs() > y[2 * peak].abs()) peak = f;
        }
        expect((peak - click).abs() / _sr, lessThanOrEqualTo(0.005), reason: 'key $key, click $click');
        expect(y[2 * peak].abs(), greaterThan(0.15));
      }
      _expectLevel(x, y);
    }
  });

  test('a loud stereo chord retains interchannel phase and loudness without clipping', () {
    final x = Float32List(2 * (_sr + 177));
    for (var f = 0; f < x.length ~/ 2; f++) {
      final t = 2 * math.pi * f / _sr;
      final v = 0.36 * math.sin(220 * t) + 0.32 * math.sin(330 * t) + 0.24 * math.sin(440 * t);
      x[2 * f] = v;
      x[2 * f + 1] = -0.38 * v;
    }
    for (final key in [-6, 5]) {
      final y = shiftKey(x, channels: 2, sampleRate: _sr, semitones: key);
      var stereoError = 0.0;
      for (var i = 0; i < y.length; i += 2) {
        stereoError = math.max(stereoError, (y[i + 1] + 0.38 * y[i]).abs());
      }
      expect(stereoError, lessThan(1e-6));
      _expectLevel(x, y);
    }
  });
}

double _frequency(Float32List x) {
  final crossings = <double>[];
  for (var i = _sr ~/ 4; i < 3 * _sr ~/ 4; i++) {
    if (x[i - 1] < 0 && x[i] >= 0) crossings.add(i - x[i] / (x[i] - x[i - 1]));
  }
  return (crossings.length - 1) * _sr / (crossings.last - crossings.first);
}

void _expectLevel(Float32List x, Float32List y) {
  double energy(Float32List samples) => samples.fold(0, (sum, v) => sum + v * v);
  final db = 10 * math.log(energy(y) / energy(x)) / math.ln10;
  expect(db.abs(), lessThanOrEqualTo(1));
  expect(y.fold(0.0, (peak, v) => math.max(peak, v.abs())), lessThan(1));
}
