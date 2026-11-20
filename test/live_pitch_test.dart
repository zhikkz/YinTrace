// The live pitch tracker against room noise: what a phone hears while
// someone sings (test/support/noisy_room.dart). The plain tracker (YIN with
// a fixed level gate, as practice used before) is the reference.
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/practice/live_pitch.dart';

import 'support/noisy_room.dart';

/// Both trackers over the same scenes (singers with different ranges).
({SceneScore plain, SceneScore tuned}) compare(
  RoomNoise? noise,
  double noiseDb, {
  double voiceDb = -20,
  bool agc = false,
  List<double> phraseDb = const [0],
  int seeds = 2,
}) {
  const ranges = [(57.0, 74.0), (45.0, 62.0), (50.0, 67.0)];
  final plain = <SceneScore>[], tuned = <SceneScore>[];
  for (var s = 0; s < seeds; s++) {
    final (low, high) = ranges[s % ranges.length];
    final take = singTake(seed: s + 1, low: low, high: high, phraseDb: phraseDb);
    final room = noise == null ? null : roomNoise(noise, take.seconds, noiseDb, seed: s + 11);
    final audio = mixScene(take, room, voiceDb: voiceDb, agc: agc);
    plain.add(
      scoreScene(
        take,
        trackScene(LivePitchTracker(sampleRate: roomRate, options: const LivePitchOptions.plain()), audio),
      ),
    );
    tuned.add(scoreScene(take, trackScene(LivePitchTracker(sampleRate: roomRate), audio)));
  }
  return (plain: _sum(plain), tuned: _sum(tuned));
}

SceneScore _sum(List<SceneScore> s) => SceneScore(
  absentFrames: s.fold(0, (a, x) => a + x.absentFrames),
  falseVoiced: s.fold(0, (a, x) => a + x.falseVoiced),
  voicedFrames: s.fold(0, (a, x) => a + x.voicedFrames),
  hits: s.fold(0, (a, x) => a + x.hits),
  inTune: s.fold(0, (a, x) => a + x.inTune),
  spuriousOnsets: s.fold(0, (a, x) => a + x.spuriousOnsets),
  onsetErrors: [for (final x in s) ...x.onsetErrors],
  trueOnsets: s.fold(0, (a, x) => a + x.trueOnsets),
  absentSeconds: s.fold(0.0, (a, x) => a + x.absentSeconds),
);

void main() {
  group('singing is tracked as well as before', () {
    for (final (name, voiceDb, phraseDb, agc) in [
      ('clean', -20.0, const [0.0], false),
      ('soft', -36.0, const [0.0], false),
      ('phrases 16 dB apart', -20.0, const [0.0, -16.0, -8.0], false),
      ('phrases 16 dB apart, AGC', -20.0, const [0.0, -16.0, -8.0], true),
    ]) {
      test(name, () {
        final r = compare(null, 0, voiceDb: voiceDb, phraseDb: phraseDb, agc: agc);
        expect(r.tuned.recall, greaterThan(math.min(0.985, r.plain.recall - 0.005)));
        expect(r.tuned.pitchAccuracy, greaterThan(r.plain.pitchAccuracy - 0.005));
        expect(r.tuned.falseVoicedRate, lessThan(0.005));
        expect(r.tuned.spuriousOnsets, 0);
        // Held-back starts keep their timing.
        expect(r.tuned.onsetRecall, greaterThanOrEqualTo(math.min(0.9, r.plain.onsetRecall - 0.03)));
        expect(r.tuned.onsetErrorQuantile(0.9), lessThan(0.03));
      });
    }
  });

  group('room noise is not taken for singing', () {
    test('appliance hum', () {
      for (final agc in [false, true]) {
        final r = compare(RoomNoise.hum, -48, agc: agc);
        expect(r.plain.falseVoicedRate, greaterThan(0.7), reason: 'the scene must be a hard one');
        expect(r.tuned.falseVoicedRate, lessThan(0.3), reason: 'agc: $agc');
        expect(r.tuned.recall, greaterThan(0.98));
      }
    });

    test('knocks and typing', () {
      for (final (noise, db) in [(RoomNoise.knocks, -30.0), (RoomNoise.keyboard, -32.0)]) {
        for (final agc in [false, true]) {
          final r = compare(noise, db, agc: agc);
          expect(r.plain.spuriousOnsets, greaterThan(0), reason: 'the scene must be a hard one');
          expect(r.tuned.spuriousOnsets, 0, reason: '$noise, agc: $agc');
          expect(r.tuned.falseVoicedRate, lessThan(0.005));
          expect(r.tuned.recall, greaterThan(0.98));
        }
      }
    });

    test('a TV or other talkers well below the singer', () {
      for (final (noise, db) in [(RoomNoise.tv, -50.0), (RoomNoise.babble, -42.0)]) {
        final r = compare(noise, db);
        expect(r.tuned.falseVoicedRate, lessThan(0.6 * r.plain.falseVoicedRate), reason: '$noise');
        expect(r.tuned.spuriousOnsets, lessThan(r.plain.spuriousOnsets), reason: '$noise');
        expect(r.tuned.recall, greaterThan(0.98));
      }
    });

    test('broadband noise keeps recall and pitch', () {
      for (final (noise, db) in [(RoomNoise.pink, -35.0), (RoomNoise.fan, -35.0), (RoomNoise.rumble, -30.0)]) {
        final r = compare(noise, db);
        expect(r.tuned.falseVoicedRate, lessThan(0.005), reason: '$noise');
        expect(r.tuned.recall, greaterThan(r.plain.recall - 0.06), reason: '$noise');
        expect(r.tuned.pitchAccuracy, greaterThan(r.plain.pitchAccuracy - 0.005), reason: '$noise');
      }
    });
  });

  group('held-back starts', () {
    const sr = roomRate;
    Float32List tone(double seconds, double hz, {double startAt = 0, double amp = 0.3}) {
      final out = Float32List((seconds * sr).round());
      for (var i = (startAt * sr).round(); i < out.length; i++) {
        out[i] = amp * math.sin(2 * math.pi * hz * i / sr);
      }
      return out;
    }

    test('come out in order with their own times', () {
      final tracker = LivePitchTracker(sampleRate: sr, options: const LivePitchOptions(latencySeconds: 0.1));
      final audio = tone(2, 220, startAt: 1);
      final out = <LivePitch>[];
      for (var i = 0; i < audio.length; i += 256) {
        out.addAll(
          tracker.addBlock(Float32List.sublistView(audio, i, math.min(audio.length, i + 256)), 5 * sr + i, i, true),
        );
      }
      for (var k = 1; k < out.length; k++) {
        expect(out[k].clockTime - out[k - 1].clockTime, closeTo(0.01, 1e-9));
        expect(out[k].songTime - out[k - 1].songTime, closeTo(0.01, 1e-9));
      }
      // Every analysed frame is reported, except the last few of an
      // undecided start (none here: the tone goes on).
      final frames = ((audio.length - 2048) / 441).floor() + 1;
      expect(out.length, frames);
      final first = out.firstWhere((p) => p.voiced);
      // Song time = 5 s + frame centre - latency; the window reaches the
      // tone half a window (23 ms) before its centre does.
      expect(first.songTime, closeTo(5 + 1 - 0.1, 0.03));
      expect(first.midi, closeTo(hzToMidi(220), 0.1));
      expect(out.where((p) => p.songTime > 6.0).every((p) => p.voiced), isTrue);
    });

    test('a blip shorter than a start is dropped, and reset forgets what was held', () {
      final tracker = LivePitchTracker(sampleRate: sr);
      // 1 s of silence, then 10 ms of tone: some frames see it, too few to start.
      final blip = tone(1.01, 440, startAt: 1.0);
      final quiet = Float32List(sr ~/ 2);
      final out = [...tracker.addBlock(blip, 0, 0, true), ...tracker.addBlock(quiet, blip.length, blip.length, true)];
      expect(out.where((p) => p.voiced), isEmpty);
      // A start in progress is dropped by reset: nothing from before it comes out later.
      final start = tone(1.02, 330, startAt: 1.0);
      tracker.addBlock(start, 0, 0, true);
      tracker.reset();
      final after = tracker.addBlock(tone(0.5, 330), 10 * sr, 10 * sr, true);
      expect(after, isNotEmpty);
      expect(after.every((p) => p.songTime >= 10), isTrue);
    });
  });
}
