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

/// One sung note: harmonics (1/k) with breath noise, vibrato after 0.3 s.
Float32List note({
  required double seconds,
  required double start,
  required double length,
  required double midi,
  double db = -20,
  double breath = 0,
  double wobbleCents = 0,
  double vibratoCents = 0,
  int seed = 1,
  double roomDb = -70,
}) {
  final rng = math.Random(seed);
  double gauss() {
    double u, v, r;
    do {
      u = rng.nextDouble() * 2 - 1;
      v = rng.nextDouble() * 2 - 1;
      r = u * u + v * v;
    } while (r >= 1 || r == 0);
    return u * math.sqrt(-2 * math.log(r) / r);
  }

  final n = (seconds * roomRate).round();
  final out = Float32List(n);
  final room = math.pow(10, roomDb / 20).toDouble();
  final amp = math.pow(10, db / 20).toDouble() * math.sqrt(2) / 1.3;
  final a = (start * roomRate).round(), b = math.min(n, ((start + length) * roomRate).round());
  var phase = 0.0, wobble = 0.0;
  for (var i = 0; i < n; i++) {
    var v = room * gauss();
    if (i >= a && i < b) {
      final t = (i - a) / roomRate;
      wobble += (gauss() * wobbleCents - wobble) * 0.002;
      final m = midi + wobble / 100 + (t > 0.3 ? vibratoCents / 100 * math.sin(2 * math.pi * 5.5 * t) : 0);
      phase += midiToHz(m) / roomRate;
      final env = math.min(1.0, math.min(t / 0.03, (b - i) / roomRate / 0.04));
      var x = 0.0;
      for (var k = 1; k <= 8; k++) {
        x += math.sin(2 * math.pi * k * phase) / k;
      }
      v += env * amp * (x + breath * gauss());
    }
    out[i] = v;
  }
  return out;
}

/// Share of frames in [a, b) seconds reported voiced.
double voicedShare(List<LivePitch> p, double a, double b) {
  final f = p.where((x) => x.songTime >= a && x.songTime < b).toList();
  return f.where((x) => x.voiced).length / math.max(1, f.length);
}

List<LivePitch> track(Float32List audio, {bool plain = false}) => trackScene(
  LivePitchTracker(sampleRate: roomRate, options: plain ? const LivePitchOptions.plain() : const LivePitchOptions()),
  audio,
);

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
      ('a soft phrase 20 dB under a loud one', -20.0, const [0.0, -20.0], false),
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

  group('singing that used to be lost', () {
    test('a breathy voice in a quiet room', () {
      for (final midi in [45.0, 57.0, 69.0]) {
        final audio = note(seconds: 2, start: 0.3, length: 1.5, midi: midi, db: -22, breath: 0.5, vibratoCents: 30);
        expect(voicedShare(track(audio, plain: true), 0.45, 1.7), greaterThan(0.95), reason: 'plain YIN hears it');
        expect(voicedShare(track(audio), 0.45, 1.7), greaterThan(0.95), reason: 'midi $midi');
      }
    });

    test('a note held very straight does not block its pitch afterwards', () {
      final first = note(seconds: 6, start: 0.5, length: 4, midi: 57, wobbleCents: 1);
      final again = note(seconds: 3, start: 0.5, length: 2, midi: 57, wobbleCents: 6, seed: 2);
      final audio = Float32List(first.length + again.length)
        ..setAll(0, first)
        ..setAll(first.length, again);
      final p = track(audio);
      expect(voicedShare(p, 0.7, 4.3), greaterThan(0.97), reason: 'the held note');
      expect(voicedShare(p, 6.7, 8.3), greaterThan(0.97), reason: 'the same pitch again');
    });

    test('a voice 10 dB over a fan or pink noise', () {
      for (final noise in [RoomNoise.fan, RoomNoise.pink]) {
        final r = compare(noise, -30, seeds: 3);
        expect(r.tuned.recall, greaterThan(r.plain.recall - 0.02), reason: '$noise');
        expect(r.tuned.pitchAccuracy, greaterThan(r.plain.pitchAccuracy), reason: '$noise');
        expect(r.tuned.falseVoicedRate, lessThan(0.005), reason: '$noise');
      }
    });
  });

  group('room noise is not taken for singing', () {
    test('appliance hum with nobody singing', () {
      for (final db in [-48.0, -40.0]) {
        for (final seed in [1, 2]) {
          final hum = roomNoise(RoomNoise.hum, 12, db, seed: seed);
          final audio = Float32List.fromList(hum);
          expect(voicedShare(track(audio, plain: true), 3, 12), greaterThan(0.9), reason: 'plain YIN takes it');
          // A machine shows within 2 s; from then on it is the room.
          expect(voicedShare(track(audio), 3, 12), lessThan(0.01), reason: '$db dB, seed $seed');
        }
      }
    });

    test('appliance hum before the singer starts, and louder hum', () {
      final take = singTake(seed: 2, low: 50, high: 67);
      const intro = 8.0;
      final voice = mixScene(take, null);
      final audio = Float32List(voice.length + (intro * roomRate).round());
      audio.setAll((intro * roomRate).round(), voice);
      final hum = roomNoise(RoomNoise.hum, audio.length / roomRate, -48, seed: 3);
      for (var i = 0; i < audio.length; i++) {
        audio[i] += hum[i];
      }
      final p = track(audio);
      expect(voicedShare(p, 3, intro), lessThan(0.02), reason: 'the intro');
      for (final db in [-40.0, -35.0]) {
        final r = compare(RoomNoise.hum, db);
        expect(r.tuned.falseVoicedRate, lessThan(0.5 * r.plain.falseVoicedRate), reason: '$db dB');
        expect(r.tuned.recall, greaterThan(r.plain.recall - 0.03), reason: '$db dB');
      }
    });

    test('appliance hum while singing', () {
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
      for (final (noise, db, share) in [(RoomNoise.tv, -50.0, 0.7), (RoomNoise.babble, -42.0, 0.9)]) {
        final r = compare(noise, db);
        expect(r.tuned.falseVoicedRate, lessThan(share * r.plain.falseVoicedRate), reason: '$noise');
        expect(r.tuned.spuriousOnsets, lessThanOrEqualTo(r.plain.spuriousOnsets), reason: '$noise');
        expect(r.tuned.recall, greaterThan(0.98));
      }
    });

    test('broadband noise keeps recall and pitch', () {
      for (final (noise, db) in [(RoomNoise.pink, -35.0), (RoomNoise.fan, -35.0), (RoomNoise.rumble, -30.0)]) {
        final r = compare(noise, db);
        expect(r.tuned.falseVoicedRate, lessThan(0.005), reason: '$noise');
        expect(r.tuned.recall, greaterThan(r.plain.recall - 0.01), reason: '$noise');
        expect(r.tuned.spuriousOnsets, lessThanOrEqualTo(r.plain.spuriousOnsets), reason: '$noise');
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

    test('a confirmed onset excludes known hum at the same pitch', () {
      final audio = tone(4, 220, amp: 0.012);
      const onset = 3.5;
      // Let the hum get 11 dB louder, then start a loud note at its pitch.
      for (var i = 3 * sr; i < audio.length; i++) {
        audio[i] *= i < onset * sr ? 3.6 : 13.0;
      }
      final pitches = track(audio);
      // Before the analysis window can see the louder note, only hum is present.
      expect(voicedShare(pitches, onset - 0.15, onset - 0.025), 0);
      expect(voicedShare(pitches, 3.55, 3.9), greaterThan(0.95));
    });

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

    test('a blip shorter than a start is dropped', () {
      // 1 s of silence, then 25 ms of tone: a frame or two see it, too few to start.
      final blip = tone(1.025, 440, startAt: 1.0);
      final quiet = Float32List(sr ~/ 2);
      List<LivePitch> feed(LivePitchTracker t) => [
        ...t.addBlock(blip, 0, 0, true),
        ...t.addBlock(quiet, blip.length, blip.length, true),
      ];
      expect(
        feed(LivePitchTracker(sampleRate: sr, options: const LivePitchOptions.plain())).where((p) => p.voiced),
        isNotEmpty,
        reason: 'plain YIN takes it',
      );
      expect(feed(LivePitchTracker(sampleRate: sr)).where((p) => p.voiced), isEmpty);
    });

    test('reset forgets a start being confirmed', () {
      final tracker = LivePitchTracker(sampleRate: sr);
      final audio = tone(1.2, 330, startAt: 1.0);
      // Feed until frames are being held back (fewer results than frames).
      var pushed = 0, results = 0;
      var holding = false;
      for (; pushed + 64 <= audio.length && !holding; pushed += 64) {
        results += tracker.addBlock(Float32List.sublistView(audio, pushed, pushed + 64), pushed, pushed, true).length;
        final frames = pushed + 64 < 2048 ? 0 : (pushed + 64 - 2048) ~/ 441 + 1;
        holding = results < frames;
      }
      expect(holding, isTrue, reason: 'a start must be pending');
      tracker.reset();
      final after = tracker.addBlock(tone(0.5, 330), 10 * sr, 10 * sr, true);
      expect(after, isNotEmpty);
      expect(after.every((p) => p.songTime >= 10), isTrue, reason: 'nothing held from before the reset');
    });
  });
}
