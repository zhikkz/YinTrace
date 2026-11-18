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

  /// [analyzePitchWithModel]: frames with a lower model confidence are
  /// unvoiced.
  final double modelConfidence;

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
/// level gate, octave-jump correction, median smoothing and removal of very
/// short voiced blips.
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
  final track = _finish(x, midi, db, ap, o);
  onProgress?.call(1);
  return track;
}

/// Extracts a cleaned pitch contour from a (separated) vocal track with the
/// pitch model (SwiftF0).
///
/// The frames are the frames of [analyzePitch], with the same level and
/// change of sound, and the same clean-up afterwards; only the pitch, and
/// whether a frame is voiced, come from the model. The model's own frames
/// are 16 ms apart: [PitchAnalysisOptions.modelShifts] runs on copies of
/// the vocal delayed by fractions of a frame put them closer together, and
/// each frame of the grid takes the confidence and pitch between the two
/// model frames around it.
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
      await model.analyze(delayed, onProgress: (f) => onProgress?.call((k + f) / shifts * 0.85)),
    ));
  }
  // The model's frames in time order: frame i of the run delayed by d is
  // centred at (i * hop - d) / 16 kHz, so for each i the most delayed run
  // comes first.
  var count = 0;
  for (final (_, r) in runs) {
    count += r.length;
  }
  final times = Float64List(count), hz = Float32List(count), conf = Float32List(count);
  var j = 0;
  for (var i = 0; j < count; i++) {
    for (final (delay, r) in runs.reversed) {
      if (i >= r.length) continue;
      times[j] = (i * SwiftF0.hop - delay) / SwiftF0.sampleRate;
      hz[j] = r.hz[i];
      conf[j] = r.confidence[i];
      j++;
    }
  }
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
    if (c < o.modelConfidence) continue;
    final va = conf[a] >= o.modelConfidence && hz[a] > 0;
    final vb = conf[b] >= o.modelConfidence && hz[b] > 0;
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
  onProgress?.call(0.9);
  final track = _finish(x, midi, db, ap, o);
  onProgress?.call(1);
  return track;
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
  // Level gate relative to the loud (voiced) part of the track.
  final voicedLevels = <double>[];
  for (var f = 0; f < frames; f++) {
    if (midi[f] > 0) voicedLevels.add(db[f]);
  }
  if (voicedLevels.isNotEmpty) {
    voicedLevels.sort();
    final p95 = voicedLevels[(voicedLevels.length * 0.95).floor().clamp(0, voicedLevels.length - 1)];
    final gate = math.max(o.absoluteGateDb, p95 + o.relativeGateDb);
    for (var f = 0; f < frames; f++) {
      if (db[f] < gate) midi[f] = 0;
    }
  }

  _fixOctaveJumps(midi);
  _medianSmooth(midi, 2);
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
