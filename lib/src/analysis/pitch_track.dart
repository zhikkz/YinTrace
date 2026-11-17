import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import '../dsp/resampler.dart';
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

  /// YIN aperiodicity per frame (lower = more periodic).
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

/// Options of [analyzePitch].
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
  });

  final int analysisRate;
  final int frameSize;
  final int hop;
  final double minFrequency;
  final double maxFrequency;
  final double yinThreshold;

  /// Frames with a YIN aperiodicity above this are unvoiced.
  final double maxAperiodicity;

  /// Frames quieter than (95th percentile level + this) are unvoiced; this
  /// removes residual accompaniment bleeding through the separation.
  final double relativeGateDb;
  final double absoluteGateDb;
}

/// Extracts a cleaned pitch contour from a (separated) vocal track.
///
/// [mono] is sampled at [sampleRate]. The result is resampled to
/// `options.analysisRate` first, analysed with YIN, then post-processed:
/// level gate, octave-jump correction, median smoothing and removal of very
/// short voiced blips. Unvoiced frames are kept as gaps throughout cleanup.
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
  final change = spectralChange(x, o.analysisRate, frames, hop: o.hop, size: o.frameSize);
  onProgress?.call(1);
  return PitchTrack(
      hopSeconds: o.hop / o.analysisRate, midi: midi, rmsDb: db, aperiodicity: ap, spectralChange: change);
}

/// Folds isolated octave errors back towards the local median.
void _fixOctaveJumps(Float32List midi) {
  const radius = 20;
  final n = midi.length;
  final fixed = Float32List.fromList(midi);
  final window = <double>[];
  var runStart = 0, runEnd = 0;
  for (var i = 0; i < n; i++) {
    final v = midi[i];
    if (v <= 0) continue;
    if (i >= runEnd) {
      runStart = i;
      runEnd = i + 1;
      while (runEnd < n && midi[runEnd] > 0) {
        runEnd++;
      }
    }
    window.clear();
    for (var k = math.max(runStart, i - radius); k < math.min(runEnd, i + radius + 1); k++) {
      window.add(midi[k]);
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

/// Median filter within each voiced run; never mix notes across a pause.
void _medianSmooth(Float32List midi, int radius) {
  final n = midi.length;
  final out = Float32List.fromList(midi);
  final w = <double>[];
  var runStart = 0, runEnd = 0;
  for (var i = 0; i < n; i++) {
    if (midi[i] <= 0) continue;
    if (i >= runEnd) {
      runStart = i;
      runEnd = i + 1;
      while (runEnd < n && midi[runEnd] > 0) {
        runEnd++;
      }
    }
    w.clear();
    for (var k = math.max(runStart, i - radius); k < math.min(runEnd, i + radius + 1); k++) {
      w.add(midi[k]);
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
