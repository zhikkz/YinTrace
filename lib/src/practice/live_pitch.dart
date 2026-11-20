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
    this.onsetAperiodicity = 0.25,
    this.onsetSeconds = 0.03,
    this.floorSeconds = 0.8,
    this.onsetAboveFloorDb = 12,
    this.holdAboveFloorDb = 6,
    this.transientDropDb = 9,
    this.singerRangeDb = 25,
    this.steadySeconds = 1,
    this.clearAboveFloorDb = 24,
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
       steadySeconds = double.infinity,
       clearAboveFloorDb = 0;

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

  /// A voiced stretch only starts on frames at most this aperiodic (more
  /// near [clearAboveFloorDb] over the background). Beyond it YIN mostly
  /// took the least bad lag of coloured noise; a voice over a fan or a
  /// breathy one can come close to it, so it is not YIN's own 0.15. Once
  /// started, [maxAperiodicity] holds it.
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

  /// Starts more than this far below the loudest recent singing (its
  /// phrase level, decaying by 2 dB a second) are another voice in the
  /// room, a TV. In the noisy-room evaluation 25 dB keeps a phrase 22 dB
  /// softer than the one before (22 dB lost a tenth of it) and still rejects
  /// a TV 30 dB under the singer about half the time.
  final double singerRangeDb;

  /// A clearly periodic sound that keeps its pitch within 5 cents for this
  /// long in all while well below the singer (or twice as long in one go
  /// with no singer around) is a machine (hum, a fan): from then on its
  /// pitch only starts a voiced stretch when clearly louder than it was.
  final double steadySeconds;

  /// From this far above the background a start may be as aperiodic as
  /// [maxAperiodicity]: a breathy or airy voice there is no room noise.
  final double clearAboveFloorDb;

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
    double? clearAboveFloorDb,
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
    clearAboveFloorDb: clearAboveFloorDb ?? this.clearAboveFloorDb,
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

  /// Steady tones found in the background (MIDI, level dB, clock time last
  /// heard): hum, a fan. A tone not heard for [_toneMemorySeconds] is
  /// forgotten, so a sung note mistaken for one does not stay blocked.
  final _tones = <(double, double, double)>[];
  static const _toneMemorySeconds = 10.0;

  /// The singer's usual level: voiced frames averaged over about 2 s.
  double _singerDb = double.negativeInfinity;

  /// The level of the singing over the last ~150 ms (voiced frames only),
  /// and its loudest recent value, decaying slowly: quieter voices in the
  /// room (a TV) neither lower it nor start a stretch far below it. A
  /// phrase level rather than the loudest single frame, so that the range
  /// is the singer's dynamics, not the peaks of their vowels.
  double _phraseDb = double.negativeInfinity;
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

  /// Start and pitch of the current steady stretch, and the latest raw
  /// pitches (their median: a machine's frame-to-frame jitter in noise is
  /// not a voice's drift).
  double _steadySince = 0, _steadyMidi = 0;
  final _steadyRing = <double>[];

  /// Voiced stretches started since the last [reset]: from the second on,
  /// someone has sung besides what sounds now.
  int _stretches = 0;

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
    // The engine clock stands still while stopped: a peak from before a
    // pause would never decay. The singer is heard again soon enough.
    _phraseDb = _peakDb = double.negativeInfinity;
    _stretches = 0;
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
    final (onsetGate, holdGate, roomGate) = _gates(f);
    // Without a clear period a frame only carries a voice on near its
    // pitch: what YIN finds in it further away is mostly an octave error in
    // noise.
    final canHold =
        pitched && f.levelDb >= holdGate && (clear || _voicing != _Voicing.on || (f.midi - _lastVoicedMidi).abs() <= 3);
    if (options.steadySeconds.isFinite) _learnTone(f);
    var tone = _isTone(f);
    // A clear period right where the voice just was continues it whatever
    // the background did.
    var follows =
        clear &&
        !tone &&
        f.levelDb >= o.gateDb &&
        f.clockTime - _lastVoicedClock <= 0.05 &&
        (f.midi - _lastVoicedMidi).abs() <= 1;
    if (_voicing == _Voicing.on) {
      if (canHold || follows) {
        if (!tone && !_tooSteady(f)) {
          _emitVoiced(f, out);
          return;
        }
        tone = true; // just learned as a machine, or already known
        follows = false;
      }
      _voicing = _Voicing.off;
    }
    // A start needs a period as clear as the background allows: near it,
    // YIN's own threshold; well above it, up to [maxAperiodicity] (a
    // breathy voice, or a voice over a fan: the breath and the noise in it
    // make it less periodic, not YIN's guess).
    final startable = pitched && f.aperiodicity <= _startClarity(f);
    final canStart = canHold && startable && f.levelDb >= onsetGate && drop < o.transientDropDb && !_isTone(f);
    // A voice the singer gate alone turned away (it could be the singer,
    // softly) is not the room: it must not raise the background.
    if (canHold && startable && f.levelDb >= roomGate && f.levelDb < onsetGate) f.notBackground = true;
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
    // A short dropout inside a note: carry on without a new start (but not
    // for a tone that was just turned away).
    if (follows ||
        (canHold && !tone && f.clockTime - _lastVoicedClock <= 0.05 && (f.midi - _lastVoicedMidi).abs() <= 1)) {
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

  /// The levels a frame needs to start and to continue a voiced stretch,
  /// and the start level without the singer gate (the room alone).
  (double, double, double) _gates(_Frame f) {
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
    return (math.max(onset, _peakAt(f.clockTime) - o.singerRangeDb), hold, onset);
  }

  /// The aperiodicity a frame may have to start a voiced stretch:
  /// [LivePitchOptions.onsetAperiodicity], relaxed to
  /// [LivePitchOptions.maxAperiodicity] for frames from
  /// [LivePitchOptions.clearAboveFloorDb] over the background on (over 6 dB),
  /// or in a room too quiet to measure.
  double _startClarity(_Frame f) {
    final o = options;
    final strict = math.min(o.onsetAperiodicity, o.maxAperiodicity);
    if (!strict.isFinite || strict >= o.maxAperiodicity) return o.maxAperiodicity;
    final floor = o.floorSeconds > 0 ? _floor.db : null;
    final above = floor == null ? double.infinity : f.levelDb - floor;
    final u = ((above - o.clearAboveFloorDb) / 6).clamp(0.0, 1.0);
    return strict + (o.maxAperiodicity - strict) * u;
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
    if (f.notBackground) {
      // Possibly the singer, softly: neither room nor a known tone.
    } else if (f.clockTime - _lastVoicedClock > 0.15) {
      _floor.add(f.levelDb);
    } else {
      // Between sung notes: no background time, but the room is at most
      // this loud (it is quieter while the AGC turns the singer down).
      _floor.lower(f.levelDb);
    }
    // The tone heard again, at about its level (a voice turned away at its
    // pitch but louder is not the tone, and must not make it louder).
    for (var i = 0; i < _tones.length; i++) {
      final (midi, db, _) = _tones[i];
      if (f.midi > 0 && (f.midi - midi).abs() <= 0.15 && (f.levelDb - db).abs() <= 6) {
        _tones[i] = (midi, db + 0.05 * (f.levelDb - db), f.clockTime);
      }
    }
  }

  void _confirm(List<LivePitch> out) {
    _voicing = _Voicing.on;
    _stretches++;
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
    _steadyRing.clear();
    _lead.clear();
    _held.clear();
  }

  /// Whether [f] is at the pitch of a known background tone and not louder
  /// than it by a start's margin.
  bool _isTone(_Frame f) {
    _tones.removeWhere((t) => f.clockTime - t.$3 > _toneMemorySeconds || f.clockTime < t.$3 - 1);
    for (final (midi, db, _) in _tones) {
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
    if (f.midi <= 0 || f.aperiodicity > math.min(0.15, o.maxAperiodicity)) return;
    if (f.levelDb > _singerDb - 10) return;
    // Between phrases only: the end of a sung note is not the room.
    if (f.clockTime - _lastVoicedClock <= 0.3) return;
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
  /// [LivePitchOptions.steadySeconds] in one go while no singer has been
  /// heard since the last [reset] (or well below them): that is how a
  /// machine shows. Only quiet sounds count (below [_machineDb]): a phone
  /// hears a singer next to it at about -30..-10 dBFS, a hum across the room
  /// lower, and a loud steady tone is more likely someone holding a note
  /// very straight (or an instrument in the tuner).
  static const _machineDb = -30.0;
  bool _tooSteady(_Frame f) {
    _steadyRing.add(f.midi);
    if (_steadyRing.length > 5) _steadyRing.removeAt(0);
    final m = median(_steadyRing);
    if (_steadyRing.length < 5 || (m - _steadyMidi).abs() > 0.05) {
      _steadySince = f.clockTime;
      _steadyMidi = m;
      return false;
    }
    if (f.clockTime - _steadySince < 2 * options.steadySeconds) return false;
    if (f.levelDb > _machineDb) return false;
    if (_stretches > 1 && f.levelDb > _peakAt(f.clockTime) - 10) return false;
    _addTone(f);
    return true;
  }

  void _addTone(_Frame f) {
    _floor.raiseTo(f.levelDb);
    for (var i = 0; i < _tones.length; i++) {
      if ((_tones[i].$1 - f.midi).abs() <= 0.15) {
        _tones[i] = (_tones[i].$1, math.max(_tones[i].$2, f.levelDb), f.clockTime);
        return;
      }
    }
    if (_tones.length >= 4) _tones.removeAt(0);
    _tones.add((f.midi, f.levelDb, f.clockTime));
  }

  void _emitVoiced(_Frame f, List<LivePitch> out) {
    _lastVoicedClock = f.clockTime;
    _lastVoicedMidi = f.midi;
    final hopSeconds = options.hop / sampleRate;
    _singerDb = _singerDb.isFinite ? _singerDb + (f.levelDb - _singerDb) * hopSeconds / 2 : f.levelDb;
    _phraseDb = _phraseDb.isFinite ? _phraseDb + (f.levelDb - _phraseDb) * math.min(1.0, hopSeconds / 0.15) : f.levelDb;
    if (_phraseDb >= _peakAt(f.clockTime)) {
      _peakDb = _phraseDb;
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

  /// Turned away by the singer gate alone: not evidence of the room.
  bool notBackground = false;

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
