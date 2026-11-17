import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
import '../dsp/resampler.dart';
import '../dsp/swift_f0.dart';
import '../dsp/yin.dart';

/// One real-time pitch measurement.
class LivePitch {
  const LivePitch({
    required this.songTime,
    required this.clockTime,
    required this.midi,
    required this.levelDb,
    required this.playing,
    required this.aperiodicity,
  });

  /// Position in the song the singer was following (latency compensated).
  final double songTime;

  /// Monotonic time since the engine started (for the free tuner).
  final double clockTime;

  /// MIDI pitch, or 0 when no voice was detected.
  final double midi;
  final double levelDb;
  final bool playing;

  /// How unsure the pitch is (lower = surer): YIN's aperiodicity, or one
  /// minus the pitch model's confidence.
  final double aperiodicity;

  bool get voiced => midi > 0;
  double get frequency => voiced ? midiToHz(midi) : 0;
}

/// Settings for [LivePitchTracker].
class LivePitchOptions {
  const LivePitchOptions({
    this.frameSize = 2048,
    this.hop = 441,
    this.minFrequency = 65,
    this.maxFrequency = 1200,
    this.maxAperiodicity = 0.3,
    this.gateDb = -50,
    this.latencySeconds = 0,
  });

  final int frameSize;

  /// 441 frames = 10 ms at 44.1 kHz.
  final int hop;
  final double minFrequency;
  final double maxFrequency;
  final double maxAperiodicity;

  /// Microphone level below which input counts as silence.
  final double gateDb;

  /// Total round trip latency to subtract from capture song positions.
  final double latencySeconds;

  LivePitchOptions copyWith({double? gateDb, double? latencySeconds}) => LivePitchOptions(
        frameSize: frameSize,
        hop: hop,
        minFrequency: minFrequency,
        maxFrequency: maxFrequency,
        maxAperiodicity: maxAperiodicity,
        gateDb: gateDb ?? this.gateDb,
        latencySeconds: latencySeconds ?? this.latencySeconds,
      );
}

/// Makes the [LivePitchSource] of a practice session or of free practice.
typedef LivePitchFactory = Future<LivePitchSource> Function({
  required int sampleRate,
  required LivePitchOptions options,
});

/// Turns captured microphone blocks into [LivePitch] samples.
///
/// Each captured block carries the song frame that was playing when it was
/// recorded; a source keeps that mapping so every pitch frame gets an exact
/// song position, which is what makes the per-character comparison work.
abstract class LivePitchSource {
  /// Can be changed while running (e.g. a new latency compensation).
  abstract LivePitchOptions options;

  /// Feeds one captured block; returns the samples measured since the last
  /// call, in time order.
  List<LivePitch> addBlock(Float32List samples, int songFrame, int clockFrame, bool playing);

  /// Samples measured since the last call that no block brought back yet
  /// (a model measures in the background).
  List<LivePitch> takeReady();

  /// Forgets the audio so far (after a seek, a pause, ...).
  void reset();

  /// What measures the pitch now ('SwiftF0', or 'YIN').
  String get detector;

  /// Seconds between consecutive samples.
  double get frameSeconds;

  /// Why the model stopped and YIN took over, if it did.
  String? get failure;

  /// Releases the model, if there is one.
  Future<void> close();
}

/// Converts captured microphone blocks into [LivePitch] samples with YIN.
///
/// What the app uses when the pitch model cannot run; [ModelPitchTracker]
/// is the usual source.
class LivePitchTracker implements LivePitchSource {
  LivePitchTracker({required this.sampleRate, this.options = const LivePitchOptions()})
      : _yin = Yin(
          sampleRate: sampleRate,
          frameSize: options.frameSize,
          minFrequency: options.minFrequency,
          maxFrequency: options.maxFrequency,
        ) {
    _stream = StreamingYin(_yin, hop: options.hop);
  }

  final int sampleRate;

  @override
  LivePitchOptions options;
  final Yin _yin;
  late StreamingYin _stream;
  final _clock = _CaptureClock();
  final _recent = <double>[];
  double _lastMidi = 0;

  @override
  String get detector => 'YIN';

  @override
  double get frameSeconds => options.hop / sampleRate;

  @override
  String? get failure => null;

  @override
  void reset() {
    _stream.reset();
    _clock.reset();
    _recent.clear();
    _lastMidi = 0;
  }

  @override
  List<LivePitch> takeReady() => const [];

  @override
  Future<void> close() async {}

  /// Feeds one captured block.
  @override
  List<LivePitch> addBlock(Float32List samples, int songFrame, int clockFrame, bool playing) {
    _clock.add(samples.length, songFrame, clockFrame, playing);
    final results = _stream.push(samples);
    final out = <LivePitch>[];
    for (final (center, est) in results) {
      final (songT, clockT, wasPlaying) = _clock.at(center, sampleRate, options.latencySeconds);
      final levelDb = est.rms > 1e-9 ? 20 * math.log(est.rms) / math.ln10 : -120.0;
      var midi = 0.0;
      if (est.frequency > 0 && est.aperiodicity <= options.maxAperiodicity && levelDb >= options.gateDb) {
        midi = _stabilise(hzToMidi(est.frequency));
      } else {
        _recent.clear();
      }
      _lastMidi = midi;
      out.add(LivePitch(
        songTime: songT,
        clockTime: clockT,
        midi: midi,
        levelDb: levelDb,
        playing: wasPlaying,
        aperiodicity: est.aperiodicity,
      ));
    }
    return out;
  }

  /// Short median filter plus suppression of single-frame octave jumps.
  double _stabilise(double m) {
    if (_lastMidi > 0) {
      final d = m - _lastMidi;
      if ((d.abs() - 12).abs() < 1.0 && _recent.length >= 3) {
        // A lone octave jump: keep the previous estimate's octave.
        m -= 12 * d.sign;
      }
    }
    _recent.add(m);
    if (_recent.length > 3) _recent.removeAt(0);
    return median(_recent);
  }
}

/// Converts captured microphone blocks into [LivePitch] samples with the
/// pitch model (SwiftF0).
///
/// The microphone is resampled to 16 kHz as it arrives. Every
/// [minNewFrames] frames (32 ms) the model runs in the background on the
/// newest audio, with [SwiftF0.history] frames before it, and gives out
/// the frames that have [lookahead] frames of audio after them (80 ms).
/// The model would like 10 (176 ms) before a frame is the same as in one
/// run over the whole recording, but on sung clips 4 already give 97-99%
/// of the frames that voicing and pitch, and the same accuracy against
/// hand labels. Until a run comes back the samples wait: [addBlock] and
/// [takeReady] hand them out.
///
/// If the model fails, YIN ([LivePitchTracker]) takes over for the rest of
/// the session; [failure] says why.
class ModelPitchTracker implements LivePitchSource {
  ModelPitchTracker({
    required this.sampleRate,
    required this._model,
    this._options = const LivePitchOptions(),
    this.lookahead = 4,
    this.minNewFrames = 2,
  }) : _resampler = StreamingResampler(sampleRate, SwiftF0.sampleRate);

  final int sampleRate;
  final SwiftF0 _model;

  /// Frames of audio after a frame before it is given out.
  final int lookahead;

  /// New frames that start another model run.
  final int minNewFrames;

  /// Quiet audio is brought up to this peak (-12 dBFS) for the model, by
  /// at most [_maxGain] (+18 dB); louder audio is left as it is.
  static const _modelPeak = 0.25;
  static const _maxGain = 8.0;

  LivePitchOptions _options;
  final StreamingResampler _resampler;
  final _clock = _CaptureClock();

  /// 16 kHz audio from the start of frame [_bufFrame] on.
  Float32List _buf = Float32List(1 << 14);
  int _bufFrame = 0;
  int _length = 0;
  int _emitted = 0; // frames given out
  int _ranTo = 0; // frames the latest run had
  int _generation = 0; // runs started before a reset are not used
  Future<void>? _running;
  bool _closed = false;
  final _ready = <LivePitch>[];
  LivePitchTracker? _yin;
  String? _failure;

  @override
  LivePitchOptions get options => _options;

  @override
  set options(LivePitchOptions value) {
    _options = value;
    _yin?.options = value;
  }

  @override
  String get detector => _yin == null ? 'SwiftF0' : 'YIN';

  @override
  double get frameSeconds => _yin?.frameSeconds ?? SwiftF0.frameSeconds;

  @override
  String? get failure => _failure;

  /// Whether a model run is in progress (for tests).
  bool get busy => _running != null;

  /// Frames whose audio has arrived.
  int get _available => (_bufFrame * SwiftF0.hop + _length) ~/ SwiftF0.hop;

  @override
  List<LivePitch> addBlock(Float32List samples, int songFrame, int clockFrame, bool playing) {
    final yin = _yin;
    if (yin != null) {
      final ready = takeReady();
      final measured = yin.addBlock(samples, songFrame, clockFrame, playing);
      return ready.isEmpty ? measured : [...ready, ...measured];
    }
    _clock.add(samples.length, songFrame, clockFrame, playing);
    _append(_resampler.add(samples));
    _schedule();
    return takeReady();
  }

  @override
  List<LivePitch> takeReady() {
    if (_ready.isEmpty) return const [];
    final out = List<LivePitch>.of(_ready);
    _ready.clear();
    return out;
  }

  @override
  void reset() {
    _generation++;
    _resampler.reset();
    _clock.reset();
    _bufFrame = 0;
    _length = 0;
    _emitted = 0;
    _ranTo = 0;
    _ready.clear();
    _yin?.reset();
  }

  /// Waits for the model run in progress, if any (for tests).
  Future<void> settle() async {
    while (_running != null) {
      try {
        await _running;
      } catch (_) {}
    }
  }

  @override
  Future<void> close() async {
    _closed = true;
    _generation++;
    await settle();
    await _model.model.close();
  }

  void _append(Float32List y) {
    if (_length + y.length > _buf.length) {
      final grown = Float32List(math.max(2 * _buf.length, _length + y.length));
      grown.setRange(0, _length, _buf);
      _buf = grown;
    }
    _buf.setRange(_length, _length + y.length, y);
    _length += y.length;
  }

  void _schedule() {
    if (_running != null || _closed || _yin != null) return;
    final available = _available;
    final last = available - lookahead; // the frames before it are given out
    if (available - _ranTo < minNewFrames || last <= _emitted) return;
    const hop = SwiftF0.hop;
    final from = math.max(_bufFrame, _emitted - SwiftF0.history);
    final input =
        Float32List.fromList(Float32List.sublistView(_buf, (from - _bufFrame) * hop, (available - _bufFrame) * hop));
    // The model misses voice when the audio peaks below about -26 dBFS
    // (singing away from the phone, 测量模式 without the system's gain):
    // bring quiet audio up to [_modelPeak], by at most [_maxGain]. The
    // levels compared with the microphone gate stay those of the input.
    var peak = 0.0;
    for (final v in input) {
      if (v.abs() > peak) peak = v.abs();
    }
    if (peak > 0 && peak < _modelPeak) {
      final gain = math.min(_maxGain, _modelPeak / peak);
      for (var i = 0; i < input.length; i++) {
        input[i] *= gain;
      }
    }
    _ranTo = available;
    final generation = _generation;
    _running = _model.run(input).then((frames) {
      _running = null;
      if (generation == _generation) _emit(frames, from, last);
      _schedule();
    }, onError: (Object e) {
      _running = null;
      if (!_closed) _fail(e);
    });
  }

  void _emit(SwiftF0Frames frames, int from, int last) {
    const hop = SwiftF0.hop;
    for (var i = _emitted; i < last; i++) {
      final hz = frames.hz[i - from], confidence = frames.confidence[i - from];
      final levelDb = _levelAt(i);
      final center = (i * hop * sampleRate / SwiftF0.sampleRate).round();
      final (songT, clockT, playing) = _clock.at(center, sampleRate, _options.latencySeconds);
      final voiced = confidence >= SwiftF0.voicedConfidence &&
          hz >= SwiftF0.minHz &&
          hz <= SwiftF0.maxHz &&
          levelDb >= _options.gateDb;
      _ready.add(LivePitch(
        songTime: songT,
        clockTime: clockT,
        midi: voiced ? hzToMidi(hz) : 0,
        levelDb: levelDb,
        playing: playing,
        aperiodicity: 1 - confidence,
      ));
    }
    _emitted = math.max(_emitted, last);
    // Keep what the next run reads, and the hop before it for the level.
    final keep = math.max(_bufFrame, _emitted - SwiftF0.history - 1);
    final drop = (keep - _bufFrame) * hop;
    if (drop > 0) {
      _buf.setRange(0, _length - drop, _buf, drop);
      _length -= drop;
      _bufFrame = keep;
    }
  }

  /// Level in dBFS of the 32 ms of 16 kHz audio centred on frame [i] (the
  /// hop before it and its own), without their mean.
  double _levelAt(int i) {
    const hop = SwiftF0.hop;
    final a = (i - 1) * hop - _bufFrame * hop;
    var mean = 0.0;
    for (var k = a; k < a + 2 * hop; k++) {
      if (k >= 0 && k < _length) mean += _buf[k];
    }
    mean /= 2 * hop;
    var sumSq = 0.0;
    for (var k = a; k < a + 2 * hop; k++) {
      final v = (k >= 0 && k < _length ? _buf[k] : 0.0) - mean;
      sumSq += v * v;
    }
    final rms = math.sqrt(sumSq / (2 * hop));
    return rms > 1e-9 ? 20 * math.log(rms) / math.ln10 : -120.0;
  }

  void _fail(Object error) {
    if (_yin != null) return;
    _failure = '$error'.split('\n').first;
    _yin = LivePitchTracker(sampleRate: sampleRate, options: _options);
  }
}

/// Where in the song, and on the engine's clock, each captured sample was.
class _CaptureClock {
  final _segments = Queue<_Segment>();
  int _pushed = 0;

  void add(int length, int songFrame, int clockFrame, bool playing) {
    _segments.add(_Segment(_pushed, length, songFrame, clockFrame, playing));
    _pushed += length;
  }

  void reset() {
    _segments.clear();
    _pushed = 0;
  }

  /// Song time (latency compensated), clock time and whether the song was
  /// playing at captured sample [center], counted from the first sample
  /// after the last [reset]. Centres only move forward.
  (double, double, bool) at(int center, int sampleRate, double latencySeconds) {
    // Drop segments that end before this centre.
    while (_segments.length > 1 && _segments.first.start + _segments.first.length <= center) {
      _segments.removeFirst();
    }
    final seg = _segments.firstWhere(
        (s) => center >= s.start && center < s.start + s.length,
        orElse: () => _segments.last);
    final offset = center - seg.start;
    final songT = (seg.playing ? seg.songFrame + offset : seg.songFrame) / sampleRate - latencySeconds;
    final clockT = (seg.clockFrame + offset) / sampleRate;
    return (songT, clockT, seg.playing);
  }
}

class _Segment {
  _Segment(this.start, this.length, this.songFrame, this.clockFrame, this.playing);
  final int start;
  final int length;
  final int songFrame;
  final int clockFrame;
  final bool playing;
}
