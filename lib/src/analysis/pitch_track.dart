import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import '../dsp/resampler.dart';
import '../dsp/swift_f0.dart';
import '../dsp/timbre.dart';
import '../dsp/yin.dart';

/// A frame-by-frame pitch contour.
class PitchTrack {
  PitchTrack({
    required this.hopSeconds,
    required this.midi,
    required this.rmsDb,
    required this.aperiodicity,
    this.spectralChange,
  }) : assert(midi.length == rmsDb.length &&
            midi.length == aperiodicity.length &&
            (spectralChange == null || spectralChange.length == midi.length));

  /// Time between frames; frame `i` is centred at `i * hopSeconds`.
  final double hopSeconds;

  /// MIDI pitch per frame, `0` for unvoiced frames.
  final Float32List midi;

  /// Frame level in dBFS.
  final Float32List rmsDb;

  /// How unsure the pitch is per frame (lower = surer): YIN's
  /// aperiodicity, or one minus the pitch model's confidence. Not stored.
  final Float32List aperiodicity;

  /// How fast the sound of the voice changes at each frame (the function
  /// of the same name in `dsp/timbre.dart`); null for tracks stored before
  /// it was measured.
  final Float32List? spectralChange;

  int get length => midi.length;
  double get duration => length * hopSeconds;

  bool voiced(int i) => midi[i] > 0;

  int frameAt(double seconds) => (seconds / hopSeconds).round().clamp(0, math.max(0, length - 1)).toInt();
  double timeOf(int frame) => frame * hopSeconds;

  /// Pitch at a time (0 when unvoiced / out of range).
  double midiAt(double seconds) {
    final i = (seconds / hopSeconds).round();
    if (i < 0 || i >= length) return 0;
    return midi[i];
  }
}

/// Options of [analyzePitch] and [analyzePitchWithModel].
class PitchAnalysisOptions {
  const PitchAnalysisOptions({
    this.analysisRate = 22050,
    this.frameSize = 1024,
    this.hop = 128,
    this.minFrequency = 65,
    this.maxFrequency = 1100,
    this.yinThreshold = 0.15,
    this.maxAperiodicity = 0.22,
    this.relativeGateDb = -32,
    this.absoluteGateDb = -55,
    this.modelConfidence = SwiftF0.voicedConfidence,
    this.voicedOnset = 0.7,
    this.loudnessSeconds = 1.0,
    this.onsetBelowLoudestDb = 18,
    this.holdBelowLoudestDb = 24,
    this.loudBelowLoudestDb = 8,
    this.loudBelowSingingDb = 10,
    this.modelShifts = 4,
    this.modelPeak = 0.5,
  });

  /// The frame grid: frame `f` is centred at `f * hop / analysisRate` s,
  /// whichever detector measures its pitch. Its level and the change of
  /// the sound are measured over [frameSize] samples at [analysisRate].
  final int analysisRate;
  final int frameSize;
  final int hop;

  /// YIN's search range ([analyzePitch]). The model searches its own
  /// ([SwiftF0.minHz]..[SwiftF0.maxHz]).
  final double minFrequency;
  final double maxFrequency;
  final double yinThreshold;

  /// Frames with a YIN aperiodicity above this are unvoiced.
  final double maxAperiodicity;

  /// Frames quieter than (95th percentile level + this) are unvoiced; this
  /// removes residual accompaniment bleeding through the separation.
  final double relativeGateDb;
  final double absoluteGateDb;

  /// [analyzePitchWithModel]: a voiced stretch holds while the model's
  /// confidence stays at this or above ...
  final double modelConfidence;

  /// ... and starts only where it reaches this. Reverb tails, breaths and
  /// what the separation left of the accompaniment come with confidences
  /// between the two (on two commercial songs the median of such frames
  /// was 0.6–0.7, of sung frames 0.95), so they extend a sung note but do
  /// not make lines of their own.
  final double voicedOnset;

  /// Both detectors: a frame is voiced only while it is near the loudest
  /// part of the voice within [loudnessSeconds] on either side: a voiced
  /// stretch starts no more than [onsetBelowLoudestDb] below it and holds
  /// down to [holdBelowLoudestDb] below it. Sung frames are a few dB below
  /// (10 % of them more than 7–9 dB), reverb tails and residue 20 dB and
  /// more; the gate follows the singer through quiet and loud passages,
  /// where one level for the whole song ([relativeGateDb]) cannot.
  final double loudnessSeconds;
  final double onsetBelowLoudestDb;
  final double holdBelowLoudestDb;

  /// [analyzePitchWithModel]: within this of the loudest, and no more than
  /// [loudBelowSingingDb] below the median level of the song's singing,
  /// where the singer is clearly singing, a voiced stretch starts at
  /// [modelConfidence] already: the model is less sure of some loud first
  /// syllables (0.6–0.75) than of the rest of the line. (In an interlude
  /// what the separation left is near its own loudest, but far below the
  /// singing.)
  final double loudBelowLoudestDb;
  final double loudBelowSingingDb;

  /// [analyzePitchWithModel]: the model's frames are 16 ms apart; it runs
  /// on this many copies of the vocal, each delayed by a fraction of a
  /// frame, so that its frames are 16 ms / [modelShifts] apart and voice
  /// onsets are placed as finely as the frame grid.
  final int modelShifts;

  /// [analyzePitchWithModel]: the vocal is scaled to this peak for the
  /// model, which does not normalise the level itself and misses voice in
  /// very quiet recordings.
  final double modelPeak;
}

/// Extracts a cleaned pitch contour from a (separated) vocal track with
/// YIN. [analyzePitchWithModel] does the same with the pitch model; this
/// is what the app uses when the model cannot run.
///
/// [mono] is sampled at [sampleRate]. The result is resampled to
/// `options.analysisRate` first, analysed with YIN, then post-processed:
/// level gates, octave-jump correction, median smoothing and removal of
/// very short voiced blips.
PitchTrack analyzePitch(Float32List mono, int sampleRate,
    {PitchAnalysisOptions options = const PitchAnalysisOptions(),
    void Function(double)? onProgress}) {
  final o = options;
  final List<double> x =
      sampleRate == o.analysisRate ? mono : resample(mono, sampleRate, o.analysisRate);
  final yin = Yin(
    sampleRate: o.analysisRate,
    frameSize: o.frameSize,
    minFrequency: o.minFrequency,
    maxFrequency: o.maxFrequency,
    threshold: o.yinThreshold,
  );
  final n = x.length;
  final frames = (n / o.hop).ceil();
  final midi = Float32List(frames);
  final db = Float32List(frames);
  final ap = Float32List(frames);
  final half = o.frameSize ~/ 2;
  final buf = Float64List(o.frameSize);
  for (var f = 0; f < frames; f++) {
    final start = f * o.hop - half; // frame centred on f*hop
    for (var i = 0; i < o.frameSize; i++) {
      final j = start + i;
      buf[i] = (j >= 0 && j < n) ? x[j] : 0.0;
    }
    final est = yin.analyze(buf);
    db[f] = est.rms > 1e-9 ? (20 * math.log(est.rms) / math.ln10) : -180;
    ap[f] = est.aperiodicity;
    if (est.frequency > 0 && est.aperiodicity <= o.maxAperiodicity) {
      midi[f] = hzToMidi(est.frequency);
    }
    if (onProgress != null && f % 2000 == 0) onProgress(f / frames * 0.9);
  }
  _gateLevel(midi, db, o);
  // YIN has no voiced stretches of its own to start and hold: its frames
  // are gated at the hold level only.
  _gateLoudness(midi, db, o, onsetBelowDb: o.holdBelowLoudestDb);
  _fixOctaveJumps(midi);
  _medianSmooth(midi, 2);
  final track = _finish(x, midi, db, ap, o);
  onProgress?.call(1);
  return track;
}

/// Extracts a cleaned pitch contour from a (separated) vocal track with the
/// pitch model (SwiftF0).
///
/// The frames are the frames of [analyzePitch], with the same level and
/// change of sound. The model's own frames are 16 ms apart:
/// [PitchAnalysisOptions.modelShifts] runs on copies of the vocal delayed by
/// fractions of a frame put them closer together.
///
/// The pitch is not each model frame's best bin on its own: where two
/// voices sound together (a lead doubled an octave lower, a harmony part),
/// or a consonant starts a note, the best bin flips between them frame by
/// frame and the melody jumps by an octave and back. [decodeMelody] takes
/// the bin scores of all frames and finds the one continuous melody that
/// they support best, so it stays with one voice. Whether a frame is
/// voiced is decided separately, from the model's confidence and the
/// loudness of the voice around the frame ([PitchAnalysisOptions]).
Future<PitchTrack> analyzePitchWithModel(Float32List mono, int sampleRate, SwiftF0 model,
    {PitchAnalysisOptions options = const PitchAnalysisOptions(), void Function(double)? onProgress}) async {
  final o = options;
  final List<double> x =
      sampleRate == o.analysisRate ? mono : resample(mono, sampleRate, o.analysisRate);
  final frames = (x.length / o.hop).ceil();
  final db = frameLevels(x, frames, hop: o.hop, size: o.frameSize);

  final input = Float32List.fromList(
      sampleRate == SwiftF0.sampleRate ? mono : resample(mono, sampleRate, SwiftF0.sampleRate));
  var peak = 0.0;
  for (final v in input) {
    if (v.abs() > peak) peak = v.abs();
  }
  if (peak > 0) {
    // At most +60 dB: what is quieter than that is no singing to find.
    final gain = math.min(1000.0, o.modelPeak / peak);
    for (var i = 0; i < input.length; i++) {
      input[i] *= gain;
    }
  }
  final shifts = math.max(1, o.modelShifts);
  final runs = <(int delay, SwiftF0Frames frames)>[];
  for (var k = 0; k < shifts; k++) {
    final delay = (k * SwiftF0.hop / shifts).round();
    final delayed = Float32List(input.length + delay)..setRange(delay, delay + input.length, input);
    runs.add((
      delay,
      await model.analyze(delayed, onProgress: (f) => onProgress?.call((k + f) / shifts * 0.75)),
    ));
  }
  // The model's frames in time order: frame i of the run delayed by d is
  // centred at (i * hop - d) / 16 kHz, so for each i the most delayed run
  // comes first.
  var count = 0;
  for (final (_, r) in runs) {
    count += r.length;
  }
  final withBins = runs.every((r) => r.$2.bins != null);
  final times = Float64List(count), hz = Float32List(count), conf = Float32List(count);
  final scores = withBins ? Float32List(count * SwiftF0.bins) : null;
  var j = 0;
  for (var i = 0; j < count; i++) {
    for (final (delay, r) in runs.reversed) {
      if (i >= r.length) continue;
      times[j] = (i * SwiftF0.hop - delay) / SwiftF0.sampleRate;
      hz[j] = r.hz[i];
      conf[j] = r.confidence[i];
      scores?.setRange(j * SwiftF0.bins, (j + 1) * SwiftF0.bins, r.bins!, i * SwiftF0.bins);
      j++;
    }
  }
  runs.clear();
  if (scores != null) {
    final melody = decodeMelody(scores, conf);
    for (var k = 0; k < count; k++) {
      hz[k] = melody[k];
    }
  }
  onProgress?.call(0.85);

  final midi = Float32List(frames);
  final ap = Float32List(frames);
  final seconds = o.hop / o.analysisRate;
  var k = 0;
  for (var f = 0; f < frames; f++) {
    final t = f * seconds;
    while (k + 1 < count && times[k + 1] <= t) {
      k++;
    }
    // Model frames a (at or before t) and b (after it).
    final a = k, b = math.min(count - 1, k + 1);
    final span = times[b] - times[a];
    final w = span > 0 ? ((t - times[a]) / span).clamp(0.0, 1.0) : 0.0;
    final c = conf[a] + (conf[b] - conf[a]) * w;
    ap[f] = 1 - c;
    final va = hz[a] > 0, vb = hz[b] > 0;
    final double m;
    if (va && vb) {
      final ma = hzToMidi(hz[a]), mb = hzToMidi(hz[b]);
      // Between two notes (or an octave slip) take the nearer frame rather
      // than a pitch neither of them has.
      m = (ma - mb).abs() <= 1 ? ma + (mb - ma) * w : (w < 0.5 ? ma : mb);
    } else if (va || vb) {
      m = hzToMidi(va ? hz[a] : hz[b]);
    } else {
      continue;
    }
    midi[f] = m;
  }
  _voiceStretches(midi, ap, db, o);
  _medianSmooth(midi, 2);
  onProgress?.call(0.9);
  final track = _finish(x, midi, db, ap, o);
  onProgress?.call(1);
  return track;
}

/// The melody the pitch model heard: for each of its frames, the pitch in
/// Hz (0 where no bin is in range) on the one path through the frames' bin
/// scores that the scores support best, where moving away from the pitch
/// of the frame before costs more the further it moves, and an octave
/// costs about as much as 20 frames (80 ms) of its scores being clearly
/// worse. [scores] holds [SwiftF0.bins] logits per frame (see
/// [SwiftF0Frames.bins]); [confidence] weighs each frame: unsure frames
/// say little about the pitch and hold it back little, so after a pause
/// the melody starts wherever the next phrase does.
///
/// Within the chosen bin the pitch is the model's own estimate: the mean
/// in log frequency of the bin and its two neighbours, weighted by their
/// softmax.
Float32List decodeMelody(Float32List scores, Float32List confidence) {
  const bins = SwiftF0.bins;
  final n = confidence.length;
  assert(scores.length == n * bins);
  final out = Float32List(n);
  if (n == 0) return out;
  // The bins the app searches.
  var lo = 0, hi = bins - 1;
  while (lo < bins && SwiftF0.binHz(lo) < SwiftF0.minHz) {
    lo++;
  }
  while (hi >= 0 && SwiftF0.binHz(hi) > SwiftF0.maxHz) {
    hi--;
  }
  final width = hi - lo + 1;
  final logHz = Float64List(width);
  for (var b = 0; b < width; b++) {
    logHz[b] = math.log(SwiftF0.binHz(lo + b));
  }
  // Moving d bins (about 0.7 semitones each) costs this, times the frame's
  // weight; one bin per frame is free, beyond three bins it gets steep.
  const band = 24;
  final cost = Float64List(2 * band + 1);
  for (var d = -band; d <= band; d++) {
    final a = d.abs();
    cost[d + band] = 0.5 * math.max(0, a - 1) + 3.0 * math.max(0, a - 3);
  }
  const jumpCost = 60.0;

  final emission = Float64List(width);
  void emissions(int t) {
    final row = t * bins + lo;
    var peak = double.negativeInfinity;
    for (var b = 0; b < width; b++) {
      peak = math.max(peak, scores[row + b]);
    }
    var sum = 0.0;
    for (var b = 0; b < width; b++) {
      sum += math.exp(scores[row + b] - peak);
    }
    final norm = peak + math.log(sum);
    final w = confidence[t].clamp(0.05, 1.0);
    for (var b = 0; b < width; b++) {
      emission[b] = w * math.max(-30.0, scores[row + b] - norm);
    }
  }

  // back[t * width + b]: the bin the path came from (or `jumped`, then it
  // came from the best bin of the frame before, in jumpFrom[t]).
  const jumped = 255;
  final back = Uint8List(n * width);
  final jumpFrom = Uint8List(n);
  var prev = Float64List(width), next = Float64List(width);
  emissions(0);
  prev.setAll(0, emission);
  for (var t = 1; t < n; t++) {
    emissions(t);
    final scale = confidence[t].clamp(0.1, 1.0);
    var best = 0;
    for (var b = 1; b < width; b++) {
      if (prev[b] > prev[best]) best = b;
    }
    jumpFrom[t] = best;
    final jump = prev[best] - scale * jumpCost;
    for (var b = 0; b < width; b++) {
      var v = jump;
      var from = jumped;
      final a0 = math.max(0, b - band), a1 = math.min(width - 1, b + band);
      for (var a = a0; a <= a1; a++) {
        final c = prev[a] - scale * cost[b - a + band];
        if (c > v) {
          v = c;
          from = a;
        }
      }
      next[b] = v + emission[b];
      back[t * width + b] = from;
    }
    final swap = prev;
    prev = next;
    next = swap;
  }
  var b = 0;
  for (var k = 1; k < width; k++) {
    if (prev[k] > prev[b]) b = k;
  }
  for (var t = n - 1; t >= 0; t--) {
    // The model's estimate within the bin: its softmax over the bin and
    // its neighbours, as the model computes its own pitch.
    final row = t * bins + lo;
    var peak = double.negativeInfinity;
    for (var k = math.max(0, b - 1); k <= math.min(width - 1, b + 1); k++) {
      peak = math.max(peak, scores[row + k]);
    }
    var sum = 0.0, acc = 0.0;
    for (var k = math.max(0, b - 1); k <= math.min(width - 1, b + 1); k++) {
      final e = math.exp(scores[row + k] - peak);
      sum += e;
      acc += e * logHz[k];
    }
    out[t] = math.exp(acc / sum);
    if (t > 0) {
      final from = back[t * width + b];
      b = from == jumped ? jumpFrom[t] : from;
    }
  }
  return out;
}

/// Voiced stretches of the model's track: a stretch starts where the
/// model is sure ([PitchAnalysisOptions.voicedOnset]) and the voice is
/// near its loudest (or where the singer is clearly singing,
/// [PitchAnalysisOptions.loudBelowLoudestDb]), and holds while the model
/// stays at [PitchAnalysisOptions.modelConfidence] and the voice within the
/// hold level and above the song's level gate
/// ([PitchAnalysisOptions.relativeGateDb]). Frames outside the stretches
/// lose their pitch.
void _voiceStretches(Float32List midi, Float32List unsure, Float32List db, PitchAnalysisOptions o) {
  final n = midi.length;
  final loudest = _loudest(db, o);
  final melody = Float32List.fromList(midi);
  // The level of the singing: of the frames the model is sure of.
  final sung = <double>[
    for (var i = 0; i < n; i++)
      if (1 - unsure[i] >= o.voicedOnset && db[i] >= o.absoluteGateDb) db[i],
  ]..sort();
  final singing = sung.isEmpty ? 0.0 : sung[sung.length ~/ 2];
  final gate = sung.isEmpty
      ? o.absoluteGateDb
      : math.max(o.absoluteGateDb, sung[(sung.length * 0.95).floor().clamp(0, sung.length - 1)] + o.relativeGateDb);
  bool holds(int i) =>
      midi[i] > 0 &&
      1 - unsure[i] >= o.modelConfidence &&
      db[i] >= gate &&
      db[i] >= loudest[i] - o.holdBelowLoudestDb;
  bool starts(int i) =>
      (1 - unsure[i] >= o.voicedOnset && db[i] >= loudest[i] - o.onsetBelowLoudestDb) ||
      (db[i] >= loudest[i] - o.loudBelowLoudestDb && db[i] >= singing - o.loudBelowSingingDb);
  var i = 0;
  while (i < n) {
    if (!holds(i)) {
      midi[i++] = 0;
      continue;
    }
    var j = i;
    var started = false;
    while (j < n && holds(j)) {
      started = started || starts(j);
      j++;
    }
    if (!started) midi.fillRange(i, j, 0);
    i = j;
  }
  // The model is less sure for a moment in the middle of a held note (two
  // voices an octave apart, a change of vowel): where the voice stays loud
  // and the melody goes on at the same pitch, the note goes on.
  final bridge = (_bridgeSeconds * o.analysisRate / o.hop).round();
  i = 1;
  while (i < n) {
    if (midi[i] > 0 || midi[i - 1] <= 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && midi[j] <= 0) {
      j++;
    }
    if (j < n && j - i <= bridge && (midi[j] - midi[i - 1]).abs() < 1) {
      var steady = true;
      for (var k = i; k < j && steady; k++) {
        steady = melody[k] > 0 &&
            (melody[k] - midi[i - 1]).abs() < 1.5 &&
            db[k] >= loudest[k] - _bridgeBelowLoudestDb;
      }
      if (steady) midi.setRange(i, j, melody, i);
    }
    i = j;
  }
}

/// [_voiceStretches] bridges a gap this long in a held note ...
const _bridgeSeconds = 0.25;

/// ... where the voice stays within this of its loudest.
const _bridgeBelowLoudestDb = 12.0;

/// YIN's frames lose their pitch where the voice is more than
/// [onsetBelowDb] below its loudest nearby.
void _gateLoudness(Float32List midi, Float32List db, PitchAnalysisOptions o, {required double onsetBelowDb}) {
  final loudest = _loudest(db, o);
  for (var i = 0; i < midi.length; i++) {
    if (db[i] < loudest[i] - onsetBelowDb) midi[i] = 0;
  }
}

/// The loudest level within [PitchAnalysisOptions.loudnessSeconds] of each
/// frame (a running maximum).
Float32List _loudest(Float32List db, PitchAnalysisOptions o) {
  final n = db.length;
  final r = math.max(1, (o.loudnessSeconds * o.analysisRate / o.hop).round());
  final out = Float32List(n);
  // Monotonic deque of indices with decreasing levels.
  final q = Int32List(n + 1);
  var head = 0, tail = 0, added = 0;
  for (var i = 0; i < n; i++) {
    final limit = math.min(n - 1, i + r);
    while (added <= limit) {
      while (tail > head && db[q[tail - 1]] <= db[added]) {
        tail--;
      }
      q[tail++] = added++;
    }
    while (q[head] < i - r) {
      head++;
    }
    out[i] = db[q[head]];
  }
  return out;
}

/// Frames quieter than the loud (voiced) part of the whole track by more
/// than [PitchAnalysisOptions.relativeGateDb] lose their pitch.
void _gateLevel(Float32List midi, Float32List db, PitchAnalysisOptions o) {
  final voicedLevels = <double>[];
  for (var f = 0; f < midi.length; f++) {
    if (midi[f] > 0) voicedLevels.add(db[f]);
  }
  if (voicedLevels.isEmpty) return;
  voicedLevels.sort();
  final p95 = voicedLevels[(voicedLevels.length * 0.95).floor().clamp(0, voicedLevels.length - 1)];
  final gate = math.max(o.absoluteGateDb, p95 + o.relativeGateDb);
  for (var f = 0; f < midi.length; f++) {
    if (db[f] < gate) midi[f] = 0;
  }
}

/// Level in dBFS of each frame of the grid: the RMS of the [size] samples
/// centred on it, without their mean (what [Yin.analyze] measures).
Float32List frameLevels(List<double> x, int frames, {required int hop, required int size}) {
  final db = Float32List(frames);
  final half = size ~/ 2;
  final n = x.length;
  for (var f = 0; f < frames; f++) {
    final start = f * hop - half;
    var mean = 0.0;
    for (var i = 0; i < size; i++) {
      final j = start + i;
      if (j >= 0 && j < n) mean += x[j];
    }
    mean /= size;
    var sumSq = 0.0;
    for (var i = 0; i < size; i++) {
      final j = start + i;
      final v = (j >= 0 && j < n ? x[j] : 0.0) - mean;
      sumSq += v * v;
    }
    final rms = math.sqrt(sumSq / size);
    db[f] = rms > 1e-9 ? (20 * math.log(rms) / math.ln10) : -180;
  }
  return db;
}

/// The clean-up shared by both detectors, and the change of sound.
PitchTrack _finish(List<double> x, Float32List midi, Float32List db, Float32List ap, PitchAnalysisOptions o) {
  final frames = midi.length;
  _removeShortRuns(midi, minFrames: math.max(3, (0.03 * o.analysisRate / o.hop).round()));
  _bridgeShortGaps(midi, maxFrames: math.max(1, (0.02 * o.analysisRate / o.hop).round()));
  final change = spectralChange(x, o.analysisRate, frames, hop: o.hop, size: o.frameSize);
  return PitchTrack(
      hopSeconds: o.hop / o.analysisRate, midi: midi, rmsDb: db, aperiodicity: ap, spectralChange: change);
}

/// Folds isolated octave errors back towards the local median.
void _fixOctaveJumps(Float32List midi) {
  const radius = 20;
  final n = midi.length;
  final fixed = Float32List.fromList(midi);
  final window = <double>[];
  for (var i = 0; i < n; i++) {
    final v = midi[i];
    if (v <= 0) continue;
    window.clear();
    for (var k = math.max(0, i - radius); k < math.min(n, i + radius + 1); k++) {
      if (midi[k] > 0) window.add(midi[k]);
    }
    if (window.length < 5) continue;
    final med = median(window);
    final d = v - med;
    if ((d - 12).abs() < 1.5) {
      fixed[i] = v - 12;
    } else if ((d + 12).abs() < 1.5) {
      fixed[i] = v + 12;
    } else if ((d - 19).abs() < 1.0) {
      fixed[i] = v - 19; // twelfth (3rd harmonic) errors
    }
  }
  midi.setAll(0, fixed);
}

/// Median filter over voiced frames only (unvoiced frames stay unvoiced).
void _medianSmooth(Float32List midi, int radius) {
  final n = midi.length;
  final out = Float32List.fromList(midi);
  final w = <double>[];
  for (var i = 0; i < n; i++) {
    if (midi[i] <= 0) continue;
    w.clear();
    for (var k = math.max(0, i - radius); k < math.min(n, i + radius + 1); k++) {
      if (midi[k] > 0) w.add(midi[k]);
    }
    out[i] = median(w);
  }
  midi.setAll(0, out);
}

void _removeShortRuns(Float32List midi, {required int minFrames}) {
  var i = 0;
  final n = midi.length;
  while (i < n) {
    if (midi[i] <= 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && midi[j] > 0) {
      j++;
    }
    if (j - i < minFrames) {
      for (var k = i; k < j; k++) {
        midi[k] = 0;
      }
    }
    i = j;
  }
}

/// Fills tiny unvoiced holes when the pitch on both sides agrees.
void _bridgeShortGaps(Float32List midi, {required int maxFrames}) {
  final n = midi.length;
  var i = 1;
  while (i < n) {
    if (midi[i] > 0 || midi[i - 1] <= 0) {
      i++;
      continue;
    }
    var j = i;
    while (j < n && midi[j] <= 0) {
      j++;
    }
    if (j < n && j - i <= maxFrames && (midi[j] - midi[i - 1]).abs() < 1.0) {
      final a = midi[i - 1], b = midi[j];
      for (var k = i; k < j; k++) {
        midi[k] = a + (b - a) * (k - i + 1) / (j - i + 1);
      }
    }
    i = j;
  }
}
