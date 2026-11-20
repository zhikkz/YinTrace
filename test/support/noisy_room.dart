import 'dart:math' as math;
import 'dart:typed_data';

import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/practice/live_pitch.dart';

/// Synthetic "phone in a room" recordings for the live pitch tracker: a
/// singer with phrase gaps, everyday room noises at phone-microphone
/// levels and, optionally, the automatic gain control of a voice-tuned
/// iPhone session. Everything is seeded, so a scene is the same on every
/// run.

const roomRate = 44100;

double _db(double db) => math.pow(10, db / 20).toDouble();

/// What the singer sang: a pitch per millisecond (0 = no voice) and where
/// the sung onsets are.
class SungTake {
  SungTake(this.voice, this.midiPerMs, this.onsets);

  /// The dry voice, its voiced parts at about 0 dBFS RMS.
  final Float64List voice;

  /// Sung pitch for every millisecond, 0 where the voice is not voiced.
  final Float32List midiPerMs;

  /// Starts of voiced notes that follow at least 60 ms without voice: what
  /// the scorer counts as onsets.
  final List<double> onsets;

  double get seconds => voice.length / roomRate;

  double midiAt(double t) {
    final i = (t * 1000).floor();
    return i < 0 || i >= midiPerMs.length ? 0 : midiPerMs[i];
  }
}

/// Renders a take of [phrases] phrases separated by pauses. [low]..[high]
/// is the singer's range (MIDI); [phraseDb] sets each phrase's level (dB,
/// cycled; the loudest phrase is normalised). The voice has vowel formants,
/// vibrato, pitch drift and shimmer, breath noise, unvoiced consonants
/// between some syllables and voiced (legato) joints between others.
SungTake singTake(
    {int seed = 1, double low = 55, double high = 72, int phrases = 3, List<double> phraseDb = const [0]}) {
  final rng = math.Random(seed);
  double uniform(double a, double b) => a + (b - a) * rng.nextDouble();
  final notes = <_Note>[];
  var t = uniform(1.2, 1.8);
  var midi = uniform(low + 2, high - 2).roundToDouble();
  for (var p = 0; p < phrases; p++) {
    final count = 4 + rng.nextInt(6);
    for (var k = 0; k < count; k++) {
      final r = rng.nextDouble();
      final dur = r < 0.3 ? uniform(0.15, 0.3) : (r < 0.85 ? uniform(0.3, 0.6) : uniform(0.6, 1.4));
      final step = rng.nextInt(9) - 4;
      midi = (midi + step).clamp(low, high);
      // How this syllable joins the previous one.
      var join = _Join.pause;
      if (k > 0) {
        final j = rng.nextDouble();
        join = j < 0.45 ? _Join.legato : (j < 0.85 ? _Join.consonant : _Join.breath);
        t += switch (join) {
          _Join.legato => 0,
          _Join.consonant => uniform(0.06, 0.12),
          _Join.breath || _Join.pause => uniform(0.15, 0.3),
        };
      }
      final glide = rng.nextDouble() < 0.15 ? (rng.nextInt(5) - 2).toDouble() : 0.0;
      final gain = phraseDb[p % phraseDb.length] + uniform(-4, 0);
      notes.add(_Note(t, t + dur, midi, glide, join, _vowels[rng.nextInt(_vowels.length)], gain));
      t += dur;
    }
    t += uniform(1.0, 2.4);
  }
  final seconds = t + 0.5;
  final n = (seconds * roomRate).round();
  final ms = (seconds * 1000).ceil();
  final pitch = Float64List(ms); // control rate: per millisecond
  final amp = Float64List(ms);
  final truth = Float32List(ms);
  final vowelAt = List<_Vowel?>.filled(ms, null);
  final onsets = <double>[];
  var jitter = 0.0;
  for (var k = 0; k < notes.length; k++) {
    final nt = notes[k];
    final next = k + 1 < notes.length ? notes[k + 1] : null;
    final legatoOut = next != null && next.join == _Join.legato;
    if (nt.join != _Join.legato) onsets.add(nt.start);
    final attack = nt.join == _Join.legato ? 0.0 : uniform(0.015, 0.05);
    final release = legatoOut ? 0.0 : uniform(0.03, 0.07);
    final vibDepth = uniform(0.15, 0.5); // semitones
    final vibRate = uniform(4.8, 6.4);
    final vibDelay = uniform(0.15, 0.35);
    final a = (nt.start * 1000).round(), b = (nt.end * 1000).round();
    for (var i = a; i < b && i < ms; i++) {
      final u = (i - a) / 1000.0, dur = (b - a) / 1000.0;
      var m = nt.midi;
      if (nt.glide != 0) {
        final w = ((u / dur - 0.4) / 0.3).clamp(0.0, 1.0);
        m += nt.glide * w;
      }
      if (nt.join == _Join.legato && k > 0 && u < 0.04) {
        // Portamento from the previous note.
        m = notes[k - 1].midi + notes[k - 1].glide + (m - notes[k - 1].midi - notes[k - 1].glide) * (u / 0.04);
      }
      if (u > vibDelay) {
        final ramp = math.min(1.0, (u - vibDelay) / 0.2);
        m += ramp * vibDepth * math.sin(2 * math.pi * vibRate * (u - vibDelay));
      }
      // Slow pitch drift, about 6 cents RMS.
      jitter = 0.995 * jitter + (rng.nextDouble() * 2 - 1) * 0.0104;
      m += jitter;
      pitch[i] = m;
      var env = 1.0;
      if (attack > 0 && u < attack) env = u / attack;
      if (nt.join == _Join.legato && u < 0.05) env = 0.35 + 0.65 * u / 0.05; // voiced consonant dip
      if (release > 0 && dur - u < release) env = math.min(env, (dur - u) / release);
      final shimmer = 1 + 0.06 * math.sin(2 * math.pi * 1.3 * u + k);
      amp[i] = env * shimmer * _db(nt.gainDb);
      truth[i] = m.toDouble();
      vowelAt[i] = nt.vowel;
    }
  }
  final voice = Float64List(n);
  var phase = 0.0;
  final noise = _Gauss(rng);
  var hp = 0.0, lastWhite = 0.0;
  final amps = Float64List(48);
  _Vowel? vowel;
  double? ampF0;
  for (var i = 0; i < n; i++) {
    final c = math.min(ms - 1, i * 1000 ~/ roomRate);
    final e = amp[c];
    if (e <= 0) continue;
    final f0 = midiToHz(pitch[c]);
    // Harmonic weights follow the vowel; recomputed when it changes.
    if (vowelAt[c] != vowel || ampF0 == null || (f0 - ampF0).abs() > ampF0 * 0.06) {
      vowel = vowelAt[c];
      ampF0 = f0;
      for (var h = 1; h < amps.length; h++) {
        final f = h * f0;
        amps[h] = f > 5000 ? 0 : vowel!.weight(f) / h;
      }
    }
    phase += f0 / roomRate;
    if (phase > 1) phase -= 1;
    final th = 2 * math.pi * phase;
    final s1 = math.sin(th), c1 = math.cos(th);
    var sPrev = 0.0, sCur = s1, v = 0.0;
    for (var h = 1; h < amps.length; h++) {
      if (amps[h] == 0) break;
      v += amps[h] * sCur;
      final sNext = 2 * c1 * sCur - sPrev;
      sPrev = sCur;
      sCur = sNext;
    }
    // Breath in the voice: high-passed noise, about 26 dB down.
    final w = noise.next();
    hp = w - lastWhite;
    lastWhite = w;
    voice[i] = e * (v + 0.035 * hp);
  }
  // Unvoiced consonants and breaths between notes.
  for (var k = 0; k < notes.length; k++) {
    final nt = notes[k];
    if (nt.join == _Join.legato) continue;
    final gap = nt.join == _Join.consonant ? (nt.start - (k > 0 ? notes[k - 1].end : nt.start - 0.08)) : 0.25;
    final a = ((nt.start - gap) * roomRate).round(), b = (nt.start * roomRate).round();
    final level = nt.join == _Join.consonant ? 0.12 : 0.03;
    var prev = 0.0;
    for (var i = math.max(0, a); i < b; i++) {
      final u = (i - a) / (b - a);
      final w = noise.next();
      final hpw = w - prev;
      prev = w;
      voice[i] += level * math.sin(math.pi * u) * hpw;
    }
  }
  // Normalise the voiced parts of the loudest phrases to 0 dBFS RMS.
  final loudest = _db(phraseDb.reduce(math.max));
  var sum = 0.0, count = 0;
  for (var i = 0; i < n; i++) {
    final c = math.min(ms - 1, i * 1000 ~/ roomRate);
    if (truth[c] > 0 && amp[c] > 0.5 * loudest) {
      sum += voice[i] * voice[i];
      count++;
    }
  }
  final g = count > 0 ? 1 / math.sqrt(sum / count) : 1.0;
  for (var i = 0; i < n; i++) {
    voice[i] *= g;
  }
  return SungTake(voice, truth, onsets);
}

enum _Join { pause, legato, consonant, breath }

class _Note {
  _Note(this.start, this.end, this.midi, this.glide, this.join, this.vowel, this.gainDb);
  final double start, end, midi, glide;
  final _Join join;
  final _Vowel vowel;
  final double gainDb;
}

class _Vowel {
  const _Vowel(this.f1, this.f2, this.f3);
  final double f1, f2, f3;

  double weight(double f) {
    double bump(double fc, double bw) {
      final d = (f - fc) / bw;
      return math.exp(-d * d);
    }

    return 0.25 + 3 * bump(f1, 120) + 2 * bump(f2, 180) + 1.2 * bump(f3, 250);
  }
}

const _vowels = [
  _Vowel(800, 1200, 2500), // a
  _Vowel(300, 2300, 3000), // i
  _Vowel(350, 800, 2400), // u
  _Vowel(500, 1900, 2500), // e
  _Vowel(500, 900, 2500), // o
];

class _Gauss {
  _Gauss(this.rng);
  final math.Random rng;
  double? _spare;

  double next() {
    final s = _spare;
    if (s != null) {
      _spare = null;
      return s;
    }
    double u, v, r;
    do {
      u = rng.nextDouble() * 2 - 1;
      v = rng.nextDouble() * 2 - 1;
      r = u * u + v * v;
    } while (r >= 1 || r == 0);
    final f = math.sqrt(-2 * math.log(r) / r);
    _spare = v * f;
    return u * f;
  }
}

/// Everyday sounds a phone microphone picks up while someone sings.
enum RoomNoise {
  white,
  pink,

  /// Traffic and building rumble: most energy below 100 Hz.
  rumble,

  /// A fan or air conditioner: low-passed noise with weak blade and motor
  /// tones.
  fan,

  /// Transformer or appliance hum: 100 Hz (or 120 Hz) with harmonics.
  hum,

  /// A television or radio: one talker with gliding pitch and syllables.
  tv,

  /// Several talkers at once.
  babble,

  /// Knocks on a table or door: decaying resonances.
  knocks,

  /// Typing on a keyboard: clicks with a short ring.
  keyboard,
}

/// [seconds] of [kind], scaled to [db] dBFS RMS. For the sparse kinds
/// (knocks, keyboard) [db] is the level of an event over its first 30 ms.
Float64List roomNoise(RoomNoise kind, double seconds, double db, {int seed = 1}) {
  final n = (seconds * roomRate).round();
  final rng = math.Random(seed * 7919 + kind.index);
  final g = _Gauss(rng);
  final x = Float64List(n);
  double uniform(double a, double b) => a + (b - a) * rng.nextDouble();
  switch (kind) {
    case RoomNoise.white:
      for (var i = 0; i < n; i++) {
        x[i] = g.next();
      }
    case RoomNoise.pink:
      _pink(x, g);
    case RoomNoise.rumble:
      // Brown noise through a gentle 15 Hz high-pass, with a slow swell
      // (a passing truck).
      var y = 0.0, z = 0.0, prev = 0.0;
      for (var i = 0; i < n; i++) {
        y = 0.997 * y + g.next();
        z = 0.998 * (z + y - prev);
        prev = y;
        x[i] = z * (1 + 0.5 * math.sin(2 * math.pi * 0.15 * i / roomRate));
      }
    case RoomNoise.fan:
      _pink(x, g);
      // Low-pass the noise at ~1.2 kHz.
      var lp = 0.0;
      final a = math.exp(-2 * math.pi * 1200 / roomRate);
      for (var i = 0; i < n; i++) {
        lp = a * lp + (1 - a) * x[i];
        x[i] = lp;
      }
      _normalise(x);
      final blade = uniform(110, 260);
      final motor = rng.nextBool() ? 100.0 : 120.0;
      var ph1 = 0.0, ph2 = 0.0, wander = 0.0;
      for (var i = 0; i < n; i++) {
        wander = 0.9999 * wander + 0.0001 * g.next();
        ph1 += blade * (1 + 0.3 * wander) / roomRate;
        ph2 += motor / roomRate;
        x[i] += 0.3 * math.sin(2 * math.pi * ph1) +
            0.12 * math.sin(4 * math.pi * ph1 + 1) +
            0.1 * math.sin(2 * math.pi * ph2);
      }
    case RoomNoise.hum:
      final f = rng.nextBool() ? 100.0 : 120.0;
      for (var i = 0; i < n; i++) {
        final t = i / roomRate;
        var v = 0.0;
        for (var h = 1; h <= 6; h++) {
          v += math.sin(2 * math.pi * f * h * t + h * 0.7) / (h * h * 0.6 + 0.4);
        }
        x[i] = v + 0.15 * math.sin(2 * math.pi * f / 2 * t) + 0.05 * g.next();
      }
    case RoomNoise.tv:
      _talker(x, rng, g, 1);
      final bed = Float64List(n);
      _pink(bed, g);
      for (var i = 0; i < n; i++) {
        x[i] += 0.05 * bed[i];
      }
    case RoomNoise.babble:
      for (var k = 0; k < 4; k++) {
        _talker(x, rng, g, 0.6 + 0.4 * rng.nextDouble());
      }
    case RoomNoise.knocks:
      var t = uniform(0.2, 0.8);
      while (t < seconds - 0.2) {
        final a = (t * roomRate).round();
        final modes = [
          for (var m = 0; m < 3; m++) (uniform(120, 900), uniform(0.006, 0.035), uniform(0.3, 1.0), uniform(0, 6.28))
        ];
        final level = _db(uniform(-6, 3));
        for (var i = a; i < math.min(n, a + roomRate ~/ 3); i++) {
          final u = (i - a) / roomRate;
          var v = 0.0;
          for (final (f, tau, w, ph) in modes) {
            v += w * math.exp(-u / tau) * math.sin(2 * math.pi * f * u + ph);
          }
          // The impact itself: a millisecond of noise.
          if (u < 0.001) v += g.next() * 0.8;
          x[i] += level * v;
        }
        t += uniform(0.35, 1.6);
      }
    case RoomNoise.keyboard:
      var t = uniform(0.2, 0.5);
      while (t < seconds - 0.2) {
        for (final (dt, weight) in [(0.0, 1.0), (uniform(0.06, 0.12), 0.6)]) {
          final a = ((t + dt) * roomRate).round();
          final ring = uniform(1500, 4000), thud = uniform(180, 420), level = _db(uniform(-6, 2)) * weight;
          for (var i = a; i < math.min(n, a + roomRate ~/ 20); i++) {
            final u = (i - a) / roomRate;
            var v = 0.6 * math.exp(-u / 0.003) * math.sin(2 * math.pi * ring * u) +
                0.5 * math.exp(-u / 0.006) * math.sin(2 * math.pi * thud * u);
            if (u < 0.002) v += g.next();
            x[i] += level * v;
          }
        }
        // Bursts of typing with pauses.
        t += rng.nextDouble() < 0.15 ? uniform(0.6, 1.5) : uniform(0.1, 0.25);
      }
  }
  final sparse = kind == RoomNoise.knocks || kind == RoomNoise.keyboard;
  if (sparse) {
    // Event level: a full-scale event has 0 dBFS RMS over its first 30 ms.
    final ref = _db(-3.5);
    for (var i = 0; i < n; i++) {
      x[i] *= ref;
    }
  } else {
    _normalise(x);
  }
  final s = _db(db);
  for (var i = 0; i < n; i++) {
    x[i] *= s;
  }
  return x;
}

void _normalise(Float64List x) {
  var sum = 0.0;
  for (final v in x) {
    sum += v * v;
  }
  final rms = math.sqrt(sum / math.max(1, x.length));
  if (rms == 0) return;
  for (var i = 0; i < x.length; i++) {
    x[i] /= rms;
  }
}

void _pink(Float64List x, _Gauss g) {
  // Paul Kellet's economy pink filter.
  var b0 = 0.0, b1 = 0.0, b2 = 0.0;
  for (var i = 0; i < x.length; i++) {
    final w = g.next();
    b0 = 0.99765 * b0 + w * 0.0990460;
    b1 = 0.96300 * b1 + w * 0.2965164;
    b2 = 0.57000 * b2 + w * 1.0526913;
    x[i] = b0 + b1 + b2 + w * 0.1848;
  }
}

/// Adds one talker: syllables of 80-250 ms at 4-6 per second with a gliding,
/// falling intonation, grouped in phrases with pauses.
void _talker(Float64List x, math.Random rng, _Gauss g, double gain) {
  double uniform(double a, double b) => a + (b - a) * rng.nextDouble();
  final n = x.length;
  final base = uniform(95, 230);
  var t = uniform(0, 0.5);
  var phase = 0.0;
  final seconds = n / roomRate;
  while (t < seconds) {
    final phraseEnd = t + uniform(1.0, 3.0);
    var f = base * uniform(1.05, 1.3);
    while (t < phraseEnd && t < seconds) {
      final dur = uniform(0.08, 0.25);
      final glide = uniform(-0.25, 0.2); // octaves over the syllable
      final level = uniform(0.5, 1.0);
      final a = (t * roomRate).round(), b = math.min(n, ((t + dur) * roomRate).round());
      final vowel = _vowels[rng.nextInt(_vowels.length)];
      final amps = [for (var h = 1; h <= 30; h++) h * f > 4000 ? 0.0 : vowel.weight(h * f) / h];
      for (var i = a; i < b; i++) {
        final u = (i - a) / (b - a);
        final hz = f * math.pow(2, glide * u);
        phase += hz / roomRate;
        final env = math.sin(math.pi * u);
        var v = 0.0;
        final th = 2 * math.pi * phase;
        for (var h = 0; h < amps.length; h++) {
          if (amps[h] == 0) break;
          v += amps[h] * math.sin((h + 1) * th);
        }
        x[i] += gain * level * env * (v + 0.08 * g.next());
      }
      f = f * math.pow(2, glide).toDouble() * uniform(0.95, 1.08);
      f = f.clamp(base * 0.8, base * 1.6);
      t += dur + (rng.nextDouble() < 0.5 ? uniform(0.02, 0.08) : 0);
    }
    t += uniform(0.3, 1.2);
  }
}

/// A voice-tuned automatic gain control like iOS applies outside
/// measurement mode: it turns loud input down within tens of milliseconds
/// and turns the gain back up, at [releaseDbPerSecond], up to [maxBoostDb]
/// while it is quiet, which makes the room louder between phrases.
Float64List applyAgc(Float64List x,
    {double targetDb = -20, double maxBoostDb = 15, double releaseDbPerSecond = 8, double attackDbPerSecond = 60}) {
  const block = 64;
  final out = Float64List(x.length);
  var power = 0.0;
  var gainDb = 0.0;
  final a = math.exp(-block / (0.02 * roomRate));
  for (var s = 0; s < x.length; s += block) {
    final e = math.min(x.length, s + block);
    var sum = 0.0;
    for (var i = s; i < e; i++) {
      sum += x[i] * x[i];
    }
    power = a * power + (1 - a) * sum / (e - s);
    final levelDb = power > 1e-14 ? 10 * math.log(power) / math.ln10 : -140.0;
    final want = (targetDb - levelDb).clamp(-20.0, maxBoostDb);
    final dt = (e - s) / roomRate;
    final next = want < gainDb
        ? math.max(want, gainDb - attackDbPerSecond * dt)
        : math.min(want, gainDb + releaseDbPerSecond * dt);
    for (var i = s; i < e; i++) {
      final u = (i - s) / (e - s);
      out[i] = x[i] * _db(gainDb + (next - gainDb) * u);
    }
    gainDb = next;
  }
  return out;
}

/// The voice at [voiceDb] dBFS plus [noise], through the AGC when [agc].
Float32List mixScene(SungTake take, Float64List? noise, {double voiceDb = -20, bool agc = false}) {
  final n = take.voice.length;
  final x = Float64List(n);
  final g = _db(voiceDb);
  for (var i = 0; i < n; i++) {
    x[i] = take.voice[i] * g + (noise != null && i < noise.length ? noise[i] : 0);
  }
  final y = agc ? applyAgc(x) : x;
  final out = Float32List(n);
  for (var i = 0; i < n; i++) {
    out[i] = y[i].clamp(-1.0, 1.0);
  }
  return out;
}

/// Runs [tracker] over [audio] in capture blocks of [block] samples (song
/// frame = sample index, as if playback started at 0).
List<LivePitch> trackScene(LivePitchTracker tracker, Float32List audio, {int block = 512}) {
  final out = <LivePitch>[];
  for (var i = 0; i < audio.length; i += block) {
    final e = math.min(audio.length, i + block);
    out.addAll(tracker.addBlock(Float32List.sublistView(audio, i, e), i, i, true));
  }
  return out;
}

/// How well the tracked pitch matches what was sung.
class SceneScore {
  SceneScore({
    required this.absentFrames,
    required this.falseVoiced,
    required this.voicedFrames,
    required this.hits,
    required this.inTune,
    required this.spuriousOnsets,
    required this.onsetErrors,
    required this.trueOnsets,
    required this.absentSeconds,
  });

  final int absentFrames, falseVoiced, voicedFrames, hits, inTune, spuriousOnsets, trueOnsets;
  final List<double> onsetErrors;
  final double absentSeconds;

  /// Share of frames without voice that were reported voiced.
  double get falseVoicedRate => absentFrames == 0 ? 0 : falseVoiced / absentFrames;

  /// Share of sung frames that were reported voiced.
  double get recall => voicedFrames == 0 ? 0 : hits / voicedFrames;

  /// Share of the reported sung frames within 50 cents of the truth.
  double get pitchAccuracy => hits == 0 ? 0 : inTune / hits;

  /// Onsets found within 150 ms of a sung onset.
  double get onsetRecall => trueOnsets == 0 ? 1 : onsetErrors.length / trueOnsets;

  double onsetErrorQuantile(double q) {
    if (onsetErrors.isEmpty) return double.nan;
    final s = [for (final e in onsetErrors) e.abs()]..sort();
    return s[math.min(s.length - 1, (q * s.length).floor())];
  }

  double get meanOnsetError =>
      onsetErrors.isEmpty ? double.nan : onsetErrors.reduce((a, b) => a + b) / onsetErrors.length;
}

/// Scores [pitches] (from [trackScene]) against [take]. Frames within
/// [margin] seconds of a voiced/unvoiced boundary are not counted: the
/// 46 ms analysis window straddles it.
SceneScore scoreScene(SungTake take, List<LivePitch> pitches, {double margin = 0.04}) {
  bool voicedNear(double t, double m) {
    for (var d = -m; d <= m + 1e-9; d += 0.005) {
      if (take.midiAt(t + d) > 0) return true;
    }
    return false;
  }

  bool unvoicedNear(double t, double m) {
    for (var d = -m; d <= m + 1e-9; d += 0.005) {
      if (take.midiAt(t + d) == 0) return true;
    }
    return false;
  }

  var absent = 0, falseVoiced = 0, voiced = 0, hits = 0, inTune = 0;
  // Onsets as the scorer sees them: voiced after >= 60 ms unvoiced.
  final detected = <double>[];
  var wasVoiced = false;
  var unvoicedSince = -1e9;
  for (final p in pitches) {
    final t = p.songTime;
    final truth = take.midiAt(t);
    if (truth == 0 && !voicedNear(t, margin)) {
      absent++;
      if (p.voiced) falseVoiced++;
    } else if (truth > 0 && !unvoicedNear(t, margin)) {
      voiced++;
      if (p.voiced) {
        hits++;
        if ((p.midi - truth).abs() <= 0.5) inTune++;
      }
    }
    if (p.voiced && !wasVoiced && t - unvoicedSince >= 0.06) detected.add(t);
    if (!p.voiced && wasVoiced) unvoicedSince = t;
    wasVoiced = p.voiced;
  }
  final errors = <double>[];
  final used = <int>{};
  for (final o in take.onsets) {
    var best = -1;
    for (var k = 0; k < detected.length; k++) {
      if ((detected[k] - o).abs() <= 0.15 && (best < 0 || (detected[k] - o).abs() < (detected[best] - o).abs())) {
        best = k;
      }
    }
    if (best >= 0) {
      errors.add(detected[best] - o);
      used.add(best);
    }
  }
  var spurious = 0;
  for (var k = 0; k < detected.length; k++) {
    if (!used.contains(k)) spurious++;
  }
  final hop = pitches.length > 1 ? pitches[1].songTime - pitches[0].songTime : 0.01;
  return SceneScore(
    absentFrames: absent,
    falseVoiced: falseVoiced,
    voicedFrames: voiced,
    hits: hits,
    inTune: inTune,
    spuriousOnsets: spurious,
    onsetErrors: errors,
    trueOnsets: take.onsets.length,
    absentSeconds: absent * hop,
  );
}
