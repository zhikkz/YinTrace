import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/pitch.dart';
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

/// Converts captured microphone blocks into [LivePitch] samples.
///
/// Each captured block carries the song frame that was playing when it was
/// recorded; the tracker keeps that mapping so every YIN frame gets an exact
/// song position, which is what makes the per-character comparison work.
class LivePitchTracker {
  LivePitchTracker({required this.sampleRate, LivePitchOptions options = const LivePitchOptions()})
      : _options = options,
        _yin = Yin(
          sampleRate: sampleRate,
          frameSize: options.frameSize,
          minFrequency: options.minFrequency,
          maxFrequency: options.maxFrequency,
        ) {
    _stream = StreamingYin(_yin, hop: options.hop);
  }

  final int sampleRate;
  LivePitchOptions _options;
  final Yin _yin;
  late StreamingYin _stream;
  int _pushed = 0;
  final _segments = Queue<_Segment>();
  final _recent = <double>[];
  double _lastMidi = 0;

  LivePitchOptions get options => _options;
  set options(LivePitchOptions o) => _options = o;

  void reset() {
    _stream.reset();
    _pushed = 0;
    _segments.clear();
    _recent.clear();
    _lastMidi = 0;
  }

  /// Feeds one captured block.
  List<LivePitch> addBlock(Float32List samples, int songFrame, int clockFrame, bool playing) {
    _segments.add(_Segment(_pushed, samples.length, songFrame, clockFrame, playing));
    _pushed += samples.length;
    final results = _stream.push(samples);
    final out = <LivePitch>[];
    for (final (center, est) in results) {
      // Centres only move forward: drop segments that end before this one.
      while (_segments.length > 1 && _segments.first.start + _segments.first.length <= center) {
        _segments.removeFirst();
      }
      final seg = _segments.firstWhere(
          (s) => center >= s.start && center < s.start + s.length,
          orElse: () => _segments.last);
      final offset = center - seg.start;
      final songT = (seg.playing ? seg.songFrame + offset : seg.songFrame) / sampleRate -
          _options.latencySeconds;
      final clockT = (seg.clockFrame + offset) / sampleRate;
      final levelDb = est.rms > 1e-9 ? 20 * math.log(est.rms) / math.ln10 : -120.0;
      var midi = 0.0;
      if (est.frequency > 0 && est.aperiodicity <= _options.maxAperiodicity && levelDb >= _options.gateDb) {
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
        playing: seg.playing,
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

class _Segment {
  _Segment(this.start, this.length, this.songFrame, this.clockFrame, this.playing);
  final int start;
  final int length;
  final int songFrame;
  final int clockFrame;
  final bool playing;
}
