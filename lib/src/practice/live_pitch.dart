import 'dart:collection';
import 'dart:math' as math;
import 'dart:typed_data';

import '../dsp/high_pass.dart';
import '../dsp/noise_floor.dart';
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
///
/// The defaults make the tracker hold out against room noise (see
/// [LivePitchTracker]); [LivePitchOptions.plain] turns all of that off.
class LivePitchOptions {
  const LivePitchOptions({
    this.frameSize = 2048,
    this.hop = 441,
    this.minFrequency = 65,
    this.maxFrequency = 1200,
    this.maxAperiodicity = 0.3,
    this.gateDb = -50,
    this.latencySeconds = 0,
    this.highPassHz = 55,
    this.onsetAperiodicity = 0.15,
    this.onsetSeconds = 0.03,
    this.floorSeconds = 0.8,
    this.onsetAboveFloorDb = 12,
    this.holdAboveFloorDb = 6,
    this.transientDropDb = 9,
    this.singerRangeDb = 22,
    this.steadySeconds = 1,
  });

  /// Plain YIN with a fixed level gate: every frame on its own.
  const LivePitchOptions.plain({
    this.frameSize = 2048,
    this.hop = 441,
    this.minFrequency = 65,
    this.maxFrequency = 1200,
    this.maxAperiodicity = 0.3,
    this.gateDb = -50,
    this.latencySeconds = 0,
  }) : highPassHz = 0,
       onsetAperiodicity = double.infinity,
       onsetSeconds = 0,
       floorSeconds = 0,
       onsetAboveFloorDb = 0,
       holdAboveFloorDb = 0,
       transientDropDb = double.infinity,
       singerRangeDb = double.infinity,
       steadySeconds = double.infinity;

  final int frameSize;

  /// 441 frames = 10 ms at 44.1 kHz.
  final int hop;
  final double minFrequency;
  final double maxFrequency;

  /// Frames above this YIN aperiodicity are unvoiced.
  final double maxAperiodicity;

  /// Microphone level below which input counts as silence.
  final double gateDb;

  /// Total round trip latency to subtract from capture song positions.
  final double latencySeconds;

  /// Cut-off of the high-pass filter in front of YIN (0 = none). Below the
  /// lowest sung fundamental (65 Hz) there is only rumble, handling noise
  /// and mains hum.
  final double highPassHz;

  /// A voiced stretch only starts on frames at most this aperiodic. Below
  /// YIN's own threshold (0.15) the frame has a clear period; above it YIN
  /// just took the least bad lag, which coloured noise often provides.
  /// Once started, [maxAperiodicity] holds it.
  final double onsetAperiodicity;

  /// How long a new voiced stretch must last before it is reported: shorter
  /// blips are noise. Its frames are held back meanwhile and then reported
  /// with their own times, so onsets keep their timing; a frame suffices
  /// when the hop is this long.
  final double onsetSeconds;

  /// Memory of the background level, in seconds of background (0 = no
  /// adaptive gate, only [gateDb]).
  final double floorSeconds;

  /// How far above the background a voiced stretch must be to start, and
  /// to go on.
  final double onsetAboveFloorDb;
  final double holdAboveFloorDb;

  /// A stretch whose newest sound has already fallen this far below the
  /// loudest of the last 60 ms is a knock or a click ringing out, not a
  /// voice.
  final double transientDropDb;

  /// Starts more than this far below the loudest recent singing (which
  /// decays by 2 dB a second) are another voice in the room, a TV. In the
  /// noisy-room evaluation 22 dB keeps a phrase 16 dB softer than the one
  /// before (20 dB already lost some of it), and a TV 30 dB under the
  /// singer is taken for singing a twelfth of the time instead of a quarter.
  final double singerRangeDb;

  /// A clearly periodic sound that keeps its pitch within 5 cents for this
  /// long in all while well below the singer (or twice as long in one go
  /// with no singer around) is a machine (hum, a fan): from then on its
  /// pitch only starts a voiced stretch when clearly louder than it was.
  final double steadySeconds;

  LivePitchOptions copyWith({
    double? gateDb,
    double? latencySeconds,
    double? highPassHz,
    double? onsetAperiodicity,
    double? onsetSeconds,
    double? floorSeconds,
    double? onsetAboveFloorDb,
    double? holdAboveFloorDb,
    double? transientDropDb,
    double? singerRangeDb,
    double? steadySeconds,
  }) => LivePitchOptions(
    frameSize: frameSize,
    hop: hop,
    minFrequency: minFrequency,
    maxFrequency: maxFrequency,
    maxAperiodicity: maxAperiodicity,
    gateDb: gateDb ?? this.gateDb,
    latencySeconds: latencySeconds ?? this.latencySeconds,
    highPassHz: highPassHz ?? this.highPassHz,
    onsetAperiodicity: onsetAperiodicity ?? this.onsetAperiodicity,
    onsetSeconds: onsetSeconds ?? this.onsetSeconds,
    floorSeconds: floorSeconds ?? this.floorSeconds,
    onsetAboveFloorDb: onsetAboveFloorDb ?? this.onsetAboveFloorDb,
    holdAboveFloorDb: holdAboveFloorDb ?? this.holdAboveFloorDb,
    transientDropDb: transientDropDb ?? this.transientDropDb,
    singerRangeDb: singerRangeDb ?? this.singerRangeDb,
    steadySeconds: steadySeconds ?? this.steadySeconds,
  );
}

enum _Voicing { off, pending, on }

/// Converts captured microphone blocks into [LivePitch] samples.
///
/// Each captured block carries the song frame that was playing when it was
/// recorded; the tracker keeps that mapping so every YIN frame gets an exact
/// song position, which is what makes the per-character comparison work.
///
/// A phone in a room hears more than the singer. Against that the tracker
/// high-passes the input, follows the level of the background and asks
/// more of a frame to start a voiced stretch than to continue one: a clear
/// period, a level well above the background, sound that does not ring out
/// like a knock, and [LivePitchOptions.onsetSeconds] of it. While a start
/// is being confirmed its frames are held back, so a call may return fewer
/// results than it analysed frames, and a later call more; they always come
/// in order.
class LivePitchTracker {
  LivePitchTracker({required this.sampleRate, this.options = const LivePitchOptions()})
    : _yin = Yin(
        sampleRate: sampleRate,
        frameSize: options.frameSize,
        minFrequency: options.minFrequency,
        maxFrequency: options.maxFrequency,
      ),
      _floor = NoiseFloor(framesPerPart: math.max(1, (options.floorSeconds * sampleRate / options.hop / 4).round())) {
    _stream = StreamingYin(_yin, hop: options.hop);
  }

  final int sampleRate;

  /// Can be changed while running (e.g. a new latency compensation).
  LivePitchOptions options;
  final Yin _yin;
  late StreamingYin _stream;
  int _pushed = 0;
  final _segments = Queue<_Segment>();
  final _recent = <double>[];

  HighPass? _highPass;

  /// Input is filtered and analysed in pieces of at most a hop (and this
  /// many samples): each piece completes at most one frame, whose YIN
  /// function is then still at hand, and the newest samples of every frame
  /// are still in [_tail].
  static const _chunk = 1024;
  final _filtered = Float64List(_chunk);
  static const _tailMask = 4095;
  final _tail = Float64List(_tailMask + 1);

  /// Level of the newest part of the last frames (a ring), to tell a knock
  /// ringing out from a voice.
  final _newest = Float64List(8);
  int _newestCount = 0;

  /// The background outlives [reset]: it belongs to the room.
  final NoiseFloor _floor;

  /// Steady tones found in the background (MIDI, level dB): hum, a fan.
  final _tones = <(double, double)>[];

  /// The singer's usual level: voiced frames averaged over about 2 s.
  double _singerDb = double.negativeInfinity;

  /// The loudest recent singing, decaying slowly: quieter voices in the room
  /// (a TV) neither lower it nor start a stretch far below it.
  double _peakDb = double.negativeInfinity, _peakClock = 0;
  double _peakAt(double clock) => _peakDb - _peakDecayDbPerSecond * math.max(0, clock - _peakClock);
  static const _peakDecayDbPerSecond = 2.0;

  var _voicing = _Voicing.off;

  /// Frames that could continue a voiced stretch but not start one, held
  /// in case a start follows: they then become its beginning.
  final _lead = <_Frame>[];

  /// Frames of a start being confirmed, and how many of them have a clear
  /// period.
  final _held = <_Frame>[];
  int _clearHeld = 0;
  double _lastVoicedClock = double.negativeInfinity;
  double _lastVoicedMidi = 0;

  /// Start and pitch of the current steady stretch.
  double _steadySince = 0, _steadyMidi = 0;

  /// Pitch of the latest voiced sound well below the singer, and how long
  /// it has held that pitch in all (it outlives [reset], like the room).
  double _quietMidi = 0, _quietSeconds = 0;

  void reset() {
    _stream.reset();
    _highPass?.reset();
    _pushed = 0;
    _segments.clear();
    _recent.clear();
    _lead.clear();
    _held.clear();
    _voicing = _Voicing.off;
    _newestCount = 0;
    _lastVoicedClock = double.negativeInfinity;
    _lastVoicedMidi = 0;
  }

  HighPass? _filter() {
    final hz = options.highPassHz;
    if (hz <= 0) return null;
    final f = _highPass;
    if (f != null && f.cutoffHz == hz) return f;
    return _highPass = HighPass(hz, sampleRate);
  }

  /// Feeds one captured block.
  List<LivePitch> addBlock(Float32List samples, int songFrame, int clockFrame, bool playing) {
    _segments.add(_Segment(_pushed, samples.length, songFrame, clockFrame, playing));
    final out = <LivePitch>[];
    final filter = _filter();
    final piece = math.min(_chunk, options.hop);
    for (var s = 0; s < samples.length; s += piece) {
      final n = math.min(piece, samples.length - s);
      if (filter != null) {
        filter.process(samples, s, n, _filtered);
      } else {
        for (var i = 0; i < n; i++) {
          _filtered[i] = samples[s + i];
        }
      }
      for (var i = 0; i < n; i++) {
        _tail[(_pushed + i) & _tailMask] = _filtered[i];
      }
      _pushed += n;
      for (final (center, est) in _stream.push(Float64List.sublistView(_filtered, 0, n))) {
        _analyse(center, est, out);
      }
    }
    return out;
  }

  void _analyse(int center, YinEstimate est, List<LivePitch> out) {
    // Centres only move forward: drop segments that end before this one.
    while (_segments.length > 1 && _segments.first.start + _segments.first.length <= center) {
      _segments.removeFirst();
    }
    final seg = _segments.firstWhere(
      (s) => center >= s.start && center < s.start + s.length,
      orElse: () => _segments.last,
    );
    final offset = center - seg.start;
    final songT = (seg.playing ? seg.songFrame + offset : seg.songFrame) / sampleRate - options.latencySeconds;
    final clockT = (seg.clockFrame + offset) / sampleRate;
    final levelDb = _db(est.rms);
    final (hz, ap) = options.highPassHz > 0 ? _subOctave(est) : (est.frequency, est.aperiodicity);
    final frame = _Frame(songT, clockT, hz > 0 ? hzToMidi(hz) : 0, levelDb, seg.playing, ap);
    _decide(frame, _newestDrop(center), out);
  }

  /// YIN's pick, or the shortest period it is a multiple of that dips
  /// nearly as deep. In noise YIN's normalisation favours long lags: a voice
  /// an octave or more too low is the commonest error it makes there.
  (double, double) _subOctave(YinEstimate est) {
    if (est.frequency <= 0) return (est.frequency, est.aperiodicity);
    final cmnd = _yin.lastCmnd;
    final lag = sampleRate / est.frequency;
    for (var k = (lag / math.max(2, _yin.minLag)).floor(); k >= 2; k--) {
      final c = (lag / k).round();
      final reach = 1 + (c * 0.03).round();
      if (c - reach < math.max(2, _yin.minLag)) continue;
      var best = c - reach;
      for (var t = c - reach + 1; t <= c + reach; t++) {
        if (cmnd[t] < cmnd[best]) best = t;
      }
      // A dip, not the edge of the search, and nearly as deep.
      if (best == c - reach || best == c + reach) continue;
      if (cmnd[best] > est.aperiodicity + 0.08) continue;
      var refined = best.toDouble();
      final s0 = cmnd[best - 1], s1 = cmnd[best], s2 = cmnd[best + 1];
      final denom = s0 - 2 * s1 + s2;
      if (denom.abs() > 1e-12) {
        final delta = 0.5 * (s0 - s2) / denom;
        if (delta.abs() < 1) refined = best + delta;
      }
      return (sampleRate / refined, cmnd[best]);
    }
    return (est.frequency, est.aperiodicity);
  }

  static double _db(double rms) => rms > 1e-9 ? 20 * math.log(rms) / math.ln10 : -120.0;

  /// How far (dB) the newest quarter of the frame centred at [center] is
  /// below the loudest newest quarter of the last 60 ms.
  double _newestDrop(int center) {
    final n = options.frameSize;
    final end = center - n ~/ 2 + n;
    final len = math.min(512, n ~/ 4);
    var sum = 0.0;
    for (var i = end - len; i < end; i++) {
      final v = _tail[i & _tailMask];
      sum += v * v;
    }
    final db = _db(math.sqrt(sum / len));
    _newest[_newestCount++ % _newest.length] = db;
    final span = math.min(_newestCount, math.min(_newest.length, 1 + (0.06 * sampleRate / options.hop).round()));
    var peak = db;
    for (var k = 1; k < span; k++) {
      peak = math.max(peak, _newest[(_newestCount - 1 - k) % _newest.length]);
    }
    return peak - db;
  }

  void _decide(_Frame f, double drop, List<LivePitch> out) {
    final o = options;
    final pitched = f.midi > 0 && f.aperiodicity <= o.maxAperiodicity;
    final clear = pitched && f.aperiodicity <= math.min(o.onsetAperiodicity, o.maxAperiodicity);
    final (onsetGate, holdGate) = _gates(f);
    // Without a clear period a frame only carries a voice on near its
    // pitch: what YIN finds in it further away is mostly an octave error in
    // noise.
    final canHold =
        pitched && f.levelDb >= holdGate && (clear || _voicing != _Voicing.on || (f.midi - _lastVoicedMidi).abs() <= 3);
    // A clear period right where the voice just was continues it whatever
    // the background did.
    final follows =
        clear &&
        f.levelDb >= o.gateDb &&
        f.clockTime - _lastVoicedClock <= 0.05 &&
        (f.midi - _lastVoicedMidi).abs() <= 1;
    if (options.steadySeconds.isFinite) _learnTone(f);
    if (_voicing == _Voicing.on) {
      if ((canHold || follows) && !_isTone(f) && !_tooSteady(f)) {
        _emitVoiced(f, out);
        return;
      }
      _voicing = _Voicing.off;
    }
    final canStart = canHold && clear && f.levelDb >= onsetGate && drop < o.transientDropDb && !_isTone(f);
    if (_voicing == _Voicing.pending) {
      // Frames without a clear period may come in between, as long as the
      // pitch goes on: noise blurs some frames of a soft start.
      final goesOn =
          canHold &&
          drop < o.transientDropDb &&
          !_isTone(f) &&
          (f.midi - _held.last.midi).abs() <= 1 &&
          _held.length < 2 * _onsetFrames;
      if (canStart || goesOn) {
        _held.add(f);
        if (canStart) _clearHeld++;
        if (_clearHeld >= _onsetFrames) _confirm(out);
        return;
      }
      // Not a voice after all (a knock ringing out, a blip): nothing of it
      // is background either.
      for (final h in _lead) {
        _emitUnvoiced(h, out);
      }
      for (final h in _held) {
        _emitUnvoiced(h, out);
      }
      _lead.clear();
      _held.clear();
      _voicing = _Voicing.off;
    }
    // A short dropout inside a note: carry on without a new start.
    if (follows || (canHold && f.clockTime - _lastVoicedClock <= 0.05 && (f.midi - _lastVoicedMidi).abs() <= 1)) {
      _flushLead(out, 0);
      _voicing = _Voicing.on;
      _emitVoiced(f, out);
      return;
    }
    if (canStart) {
      _voicing = _Voicing.pending;
      _held.add(f);
      _clearHeld = 1;
      if (_clearHeld >= _onsetFrames) _confirm(out);
      return;
    }
    if (canHold) {
      _lead.add(f);
      _flushLead(out, _leadFrames);
      return;
    }
    _flushLead(out, 0);
    _background(f, out);
  }

  /// The levels a frame needs to start and to continue a voiced stretch.
  (double, double) _gates(_Frame f) {
    final o = options;
    var onset = o.gateDb, hold = o.gateDb;
    final floor = o.floorSeconds > 0 ? _floor.db : null;
    if (floor != null) {
      // Over broadband noise a frame's aperiodicity is about the share of
      // the noise in it, so a clear period already shows the voice above
      // the noise: the margins only apply in full to sounds more periodic
      // than their level above the background explains (hum, a TV).
      final explained = -10 * math.log(math.max(f.aperiodicity, 1e-3)) / math.ln10 - 3;
      // With an AGC the room heard between phrases is louder than under
      // the voice: never ask for more than the singer's usual level.
      final cap = _singerDb.isFinite ? _singerDb - 3 : double.infinity;
      onset = math.max(onset, math.min(floor + math.min(o.onsetAboveFloorDb, explained), cap));
      hold = math.max(hold, math.min(floor + math.min(o.holdAboveFloorDb, explained), cap - 6));
    }
    return (math.max(onset, _peakAt(f.clockTime) - o.singerRangeDb), hold);
  }

  int get _onsetFrames => math.max(1, (options.onsetSeconds * sampleRate / options.hop).round());

  /// How many frames before a start may join it: as many as the start
  /// waits for, so that a soft attack keeps its time.
  int get _leadFrames => (options.onsetSeconds * sampleRate / options.hop + 1e-9).floor();

  /// Reports lead frames beyond the newest [keep] as background.
  void _flushLead(List<LivePitch> out, int keep) {
    final n = _lead.length - keep;
    if (n <= 0) return;
    for (var i = 0; i < n; i++) {
      _background(_lead[i], out);
    }
    _lead.removeRange(0, n);
  }

  void _background(_Frame f, List<LivePitch> out) {
    _emitUnvoiced(f, out);
    if (f.clockTime - _lastVoicedClock > 0.15) {
      _floor.add(f.levelDb);
    } else {
      // Between sung notes: no background time, but the room is at most
      // this loud (it is quieter while the AGC turns the singer down).
      _floor.lower(f.levelDb);
    }
    for (var i = 0; i < _tones.length; i++) {
      final (midi, db) = _tones[i];
      if ((f.midi - midi).abs() <= 0.15) _tones[i] = (midi, math.max(db - 0.02, f.levelDb));
    }
  }

  void _confirm(List<LivePitch> out) {
    _voicing = _Voicing.on;
    // The lead frames at the start's pitch are its attack.
    final first = _held.first;
    var k = _lead.length;
    while (k > 0 && (_lead[k - 1].midi - first.midi).abs() <= 1) {
      k--;
    }
    for (var i = 0; i < _lead.length; i++) {
      if (i < k) {
        _background(_lead[i], out);
      } else {
        _emitVoiced(_lead[i], out);
      }
    }
    for (final h in _held) {
      _emitVoiced(h, out);
    }
    _steadySince = (k < _lead.length ? _lead[k] : first).clockTime;
    _steadyMidi = first.midi;
    _lead.clear();
    _held.clear();
  }

  /// Whether [f] is at the pitch of a known background tone and not louder
  /// than it by a start's margin.
  bool _isTone(_Frame f) {
    for (final (midi, db) in _tones) {
      if ((f.midi - midi).abs() <= 0.15 && f.levelDb < db + options.onsetAboveFloorDb) return true;
    }
    return false;
  }

  /// Learns steady tones of the background. No voice holds its pitch
  /// within 5 cents for long, a machine does: a clearly periodic sound well
  /// below the singer that has kept one pitch for
  /// [LivePitchOptions.steadySeconds] in all (the hum between phrases,
  /// however often the singer interrupts it) is one.
  void _learnTone(_Frame f) {
    final o = options;
    if (f.midi <= 0 || f.aperiodicity > math.min(o.onsetAperiodicity, o.maxAperiodicity)) return;
    if (f.levelDb > _singerDb - 10) return;
    final dt = o.hop / sampleRate;
    if ((f.midi - _quietMidi).abs() <= 0.05) {
      _quietSeconds += dt;
      if (_quietSeconds >= o.steadySeconds) {
        _addTone(f);
        _quietSeconds = 0;
      }
    } else if ((_quietSeconds -= dt) <= 0) {
      _quietMidi = f.midi;
      _quietSeconds = 0;
    }
  }

  /// Whether a voiced stretch has kept its pitch within 5 cents for twice
  /// [LivePitchOptions.steadySeconds] in one go: with nobody louder around
  /// (no singer yet) that is how a machine shows.
  bool _tooSteady(_Frame f) {
    if ((f.midi - _steadyMidi).abs() > 0.05) {
      _steadySince = f.clockTime;
      _steadyMidi = f.midi;
      return false;
    }
    if (f.clockTime - _steadySince < 2 * options.steadySeconds) return false;
    _addTone(f);
    return true;
  }

  void _addTone(_Frame f) {
    _floor.raiseTo(f.levelDb);
    for (var i = 0; i < _tones.length; i++) {
      if ((_tones[i].$1 - f.midi).abs() <= 0.15) {
        _tones[i] = (_tones[i].$1, math.max(_tones[i].$2, f.levelDb));
        return;
      }
    }
    if (_tones.length >= 4) _tones.removeAt(0);
    _tones.add((f.midi, f.levelDb));
  }

  void _emitVoiced(_Frame f, List<LivePitch> out) {
    _lastVoicedClock = f.clockTime;
    _lastVoicedMidi = f.midi;
    _singerDb = _singerDb.isFinite ? _singerDb + (f.levelDb - _singerDb) * options.hop / sampleRate / 2 : f.levelDb;
    if (f.levelDb >= _peakAt(f.clockTime)) {
      _peakDb = f.levelDb;
      _peakClock = f.clockTime;
    }
    out.add(
      LivePitch(
        songTime: f.songTime,
        clockTime: f.clockTime,
        midi: _stabilise(f.midi),
        levelDb: f.levelDb,
        playing: f.playing,
        aperiodicity: f.aperiodicity,
      ),
    );
  }

  void _emitUnvoiced(_Frame f, List<LivePitch> out) {
    _recent.clear();
    out.add(
      LivePitch(
        songTime: f.songTime,
        clockTime: f.clockTime,
        midi: 0,
        levelDb: f.levelDb,
        playing: f.playing,
        aperiodicity: f.aperiodicity,
      ),
    );
  }

  /// Median of raw estimates: rejects one octave outlier and follows a
  /// sustained octave change as soon as two of the three frames agree.
  double _stabilise(double m) {
    _recent.add(m);
    if (_recent.length > 3) _recent.removeAt(0);
    return median(_recent);
  }
}

/// A frame waiting for its voicing to be decided.
class _Frame {
  _Frame(this.songTime, this.clockTime, this.midi, this.levelDb, this.playing, this.aperiodicity);
  final double songTime;
  final double clockTime;

  /// Raw YIN pitch (0 without a candidate).
  final double midi;
  final double levelDb;
  final bool playing;
  final double aperiodicity;
}

class _Segment {
  _Segment(this.start, this.length, this.songFrame, this.clockFrame, this.playing);
  final int start;
  final int length;
  final int songFrame;
  final int clockFrame;
  final bool playing;
}
