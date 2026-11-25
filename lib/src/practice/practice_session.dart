import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/microphone.dart';
import '../app/settings.dart';
import '../audio/playback_scrub.dart';
import '../audio/shifted_track.dart';
import '../library/song.dart';
import '../library/song_repository.dart';
import 'live_pitch.dart';
import 'scoring.dart';
import 'take_recorder.dart';

/// Track slots in the practice engine.
abstract final class TrackSlot {
  static const accompaniment = 0;
  static const guideVocal = 1;

  /// The singer's own recording, while listening back.
  static const take = 2;
}

/// What is played instead of practising.
enum ListenKind {
  /// The singer's own take (the original singer muted).
  take,

  /// The original singer, loud, to hear how a line goes.
  original,
}

/// Loads a stem into the practice engine. The progress callback is 0..1.
typedef LoadPracticeTrack = Future<void> Function(
  PracticeEngine engine,
  int slot,
  ShiftedTrack track,
  void Function(double)? onProgress,
);

/// Drives practice runs: audio engine, live pitch tracking and scoring.
class PracticeSession extends ChangeNotifier {
  PracticeSession({
    required this.meta,
    required this.reference,
    required this.repository,
    required this.settings,
    this.contour,
    this.loopLine,
    PracticeEngine Function()? engineFactory,
    OutputRoute Function()? readOutputRoute,
    this.loadTrack,
    this.decodeInBackground = true,
  }) : _engineFactory = engineFactory ?? (() => PracticeEngine.create(mode: EngineMode.duplex)),
       _readOutputRoute = readOutputRoute ?? (() => NativeAudio.outputRoute),
       _transpose = meta.transpose {
    scorer = PracticeScorer(reference, options: _scoringOptions())..onlyLine = loopLine;
  }

  final SongMeta meta;
  final SongReference reference;
  final SongRepository repository;
  final AppSettings settings;
  final PitchTrack? contour;
  final PracticeEngine Function() _engineFactory;
  final OutputRoute Function() _readOutputRoute;
  final LoadPracticeTrack? loadTrack;

  /// Decode the tracks in a background isolate (keeps the UI responsive).
  final bool decodeInBackground;

  /// When set, the run loops this line.
  int? loopLine;

  late PracticeScorer scorer;
  PracticeEngine? _engine;
  final _scrub = PlaybackScrub();
  LivePitchTracker? _tracker;
  int _endCount = 0;
  double _latency = 0;
  double _systemLatency = 0;
  OutputRoute _outputRoute = OutputRoute.unknown;
  double _clock = 0;

  /// Trail of the singer's pitch (last [_keepSeconds] seconds).
  final List<UserPoint> points = [];
  static const _keepSeconds = 30.0;

  ScoredSample? lastSample;

  /// The most recent sample with a voice (held briefly by the UI).
  ScoredSample? lastVoiced;
  String? error;
  bool finished = false;
  bool started = false;
  bool _starting = false;
  bool _disposed = false;
  bool _suspended = false;
  bool _calibrating = false;
  String? pauseReason;

  int _transpose;
  int get transpose => _transpose;
  int? _requestedTranspose;
  int get selectedTranspose => _requestedTranspose ?? _transpose;
  double? _keyShiftProgress;
  double? get keyShiftProgress => _keyShiftProgress;
  bool get changingKey => _keyShiftProgress != null;
  String? keyShiftNotice;

  /// What the singer sang in this session (null until the audio started).
  TakeRecorder? take;

  /// Where recording starts after jumping to a line: the music before it
  /// only leads in, and what was sung there before stays in the take.
  double _recordFrom = 0;

  /// The line jumped to (上一句, 下一句, 重唱这一句, after hearing the
  /// original singer): while playback is still in its lead-in, the music
  /// belongs to the line before, but this is the line being sung next.
  int? _aimLine;

  /// The run being sung (a pass through the song, or a spell of looping one
  /// line) is one record in the song's history, identified by this time.
  DateTime? _runAt;
  double _runSeconds = 0;

  /// Earlier runs of this session that are not stored yet.
  final _endedRuns = <PracticeRecord>[];
  PracticeRecord? _stored;
  Future<void> _saving = Future.value();
  static DateTime _lastRunAt = DateTime.fromMicrosecondsSinceEpoch(0);

  /// The song time span being played back, while listening back.
  (double, double)? _review;
  ListenKind? _listenKind;
  int? _originalLine; // the line played with the original singer
  double _resumeAt = 0; // where practice continues after listening back
  int? _resumeLine; // ...to sing this line, when it continues before one
  (int, int, int)? _loadedTake; // version and song-frame interval in the take slot

  PracticeEngine? get engine => _engine;
  bool get isPlaying => _scrub.isPlaying(_engine);

  bool _monitorEnabled = false;
  bool _monitorAvailable = false;

  /// The level is remembered, but each new session starts with monitoring off.
  bool get monitorEnabled => _monitorEnabled;
  bool get monitorAvailable => _monitorAvailable;

  void _refreshMonitorRoute() {
    _monitorAvailable = _engine?.monitorAvailable ?? false;
    if (!_monitorAvailable) _monitorEnabled = false;
  }

  void setMonitorEnabled(bool enabled) {
    _refreshMonitorRoute();
    final was = _monitorEnabled;
    _monitorEnabled = enabled && _monitorAvailable;
    if (_monitorEnabled != was && started && !_suspended) {
      try {
        NativeAudio.configureSession(record: true, measurement: usesMeasurementMode);
      } catch (err) {
        _log('monitor session mode: $err');
      }
    }
    applyMix();
    notifyListeners();
  }

  /// Measurement mode, which keeps iOS's voice processing (AGC, and the
  /// built-in microphone's processing delay) out of the input, also while
  /// monitoring: the monitor is only on with wired headphones, where the
  /// quieter speaker output of that mode does not matter.
  bool get usesMeasurementMode => settings.measurementMode || _monitorEnabled;

  /// Listening (to the take or the original singer) instead of practising.
  bool get reviewing => _review != null;

  /// What is being listened to (null while practising).
  ListenKind? get listening => _review == null ? null : _listenKind;

  /// The line being played with the original singer.
  int? get originalLine => listening == ListenKind.original ? _originalLine : null;

  /// Whether there is a take to listen back to (of [line], when given).
  bool canListenBack({int? line}) {
    final t = take;
    if (t == null || t.isEmpty) return false;
    if (line == null) return true;
    final (a, b) = lineSpan(line);
    return t.covers(a, b);
  }

  /// The singer's pitch trail while practising or listening back to a take.
  List<UserPoint> get displayPoints => switch (listening) {
    ListenKind.take => take!.points,
    ListenKind.original => const [],
    null => points,
  };

  /// While listening back: what the singer sang at the current position.
  UserPoint? get reviewPoint => listening == ListenKind.take ? take?.pointAt(position) : null;

  /// Total compensation applied to captured audio (seconds).
  double get latency => _latency;
  double get systemLatency => _systemLatency;
  OutputRoute get outputRoute => _outputRoute;
  int get latencyOffsetMs => settings.latencyOffsetFor(outputRoute, measurement: usesMeasurementMode);

  /// Song position the singer currently hears or is previewing by dragging.
  double get position {
    final target = _scrub.position;
    if (target != null) return target;
    final e = _engine;
    if (e == null) return 0;
    return math.max(0, e.positionSeconds - _latency / 2);
  }

  double get duration => math.max(meta.duration, _engine?.lengthSeconds ?? 0);

  ScoringOptions _scoringOptions() => ScoringOptions(
    greatCents: settings.toleranceCents.toDouble(),
    okCents: settings.toleranceCents * 2.0,
    octaveTolerant: settings.octaveTolerant,
    transpose: _transpose,
  );

  /// Opens the audio device and loads the tracks.
  Future<void> start() async {
    if (started || _starting || _disposed) return;
    _starting = true;
    try {
      final perm = await NativeAudio.requestMicPermission();
      if (_disposed) return;
      if (perm != MicPermission.granted) {
        error = microphoneDeniedMessage;
        notifyListeners();
        return;
      }
      NativeAudio.configureSession(record: true, measurement: settings.measurementMode);
      final e = _engineFactory();
      _engine = e;
      final target = _transpose;
      if (target != 0) _beginKeyShift(target);
      _transpose = await _loadKey(e, target);
      if (_disposed) return;
      await _rememberKey();
      if (_disposed) return;
      _finishKeyShift();
      take = _newTake(e);
      // applyMix() below, once the device runs, sets the scoring key and
      // the latency for the current output route.
      _endCount = e.endCount;
      if (_suspended || pauseReason != null) {
        // Backgrounding and returning while decode is still in flight must
        // not reopen the microphone before the user resumes.
        e.stop();
        e.flushCapture();
      } else {
        e.start();
      }
      applyMix();
      _tracker = LivePitchTracker(
        sampleRate: e.sampleRate,
        options: LivePitchOptions(gateDb: settings.micGateDb, latencySeconds: _latency),
      );
      started = true;
      if (loopLine != null) {
        setLoopLine(loopLine);
      }
      notifyListeners();
    } catch (err) {
      if (_disposed) return;
      _finishKeyShift();
      error = '无法启动音频：$err';
      _engine?.dispose();
      _engine = null;
      notifyListeners();
    } finally {
      _starting = false;
    }
  }

  TakeRecorder _newTake(PracticeEngine e) => TakeRecorder(
    sampleRate: e.sampleRate,
    lengthFrames: math.max(e.lengthFrames, (meta.duration * e.sampleRate).ceil()),
    transpose: _transpose,
  );

  void _beginKeyShift(int target) {
    _requestedTranspose = target;
    _keyShiftProgress = 0;
    keyShiftNotice = null;
    notifyListeners();
  }

  void _finishKeyShift() {
    _requestedTranspose = null;
    _keyShiftProgress = null;
  }

  Future<void> _loadTracks(PracticeEngine e, int key) async {
    final cache = key == 0 ? null : await repository.prepareKeyShiftCache(meta.id);
    if (_disposed) return;
    final tracks = {
      TrackSlot.accompaniment: ?meta.practiceAccompaniment,
      TrackSlot.guideVocal: meta.vocalsFile,
    };
    var index = 0;
    for (final entry in tracks.entries) {
      final track = ShiftedTrack(
        repository.pathFor(meta.id, entry.value),
        key,
        cache: cache,
        sampleRate: e.sampleRate,
      );
      void progress(double fraction) {
        final previous = _keyShiftProgress;
        if (_disposed || previous == null || key != _requestedTranspose) return;
        final next = (index + fraction.clamp(0.0, 1.0)) / tracks.length;
        if ((next * 100).floor() <= (previous * 100).floor()) return;
        _keyShiftProgress = next;
        notifyListeners();
      }

      final loader = loadTrack;
      if (loader != null) {
        await loader(e, entry.key, track, progress);
      } else if (decodeInBackground) {
        await _loadInBackground(e, entry.key, track, key == 0 ? null : progress);
      } else if (key == 0) {
        e.loadTrackFile(entry.key, track.path);
      } else {
        final audio = track.decode(onProgress: progress);
        e.loadTrackPcm(entry.key, audio.samples, audio.channels);
      }
      if (_disposed) return;
      progress(1);
      index++;
    }
  }

  /// Playback stays paused until both stems use the same key.
  Future<int> _loadKey(PracticeEngine e, int target) async {
    try {
      await _loadTracks(e, target);
      return target;
    } catch (err) {
      if (_disposed || target == 0) rethrow;
      _log('key shift $target failed: $err');
      await _loadTracks(e, 0);
      keyShiftNotice = '变调失败，已回到原调';
      return 0;
    }
  }

  Future<void> _rememberKey() async {
    if (meta.transpose == _transpose) return;
    meta.transpose = _transpose;
    try {
      await repository.saveTranspose(meta.id, _transpose);
    } catch (err) {
      _log('save key: $err');
      keyShiftNotice = keyShiftNotice == null
          ? '已切换调，没能记住这首歌的调'
          : '$keyShiftNotice。没能记住这次设置';
    }
  }

  /// Ends the old run at the key boundary and resumes at the same song frame.
  Future<void> setTranspose(int target, {bool resumeAfterSaving = false}) async {
    RangeError.checkValueInInterval(target, minTranspose, maxTranspose, 'transpose');
    final e = _engine;
    if (e == null || !started || _disposed || _calibrating || changingKey || error != null || target == _transpose) {
      return;
    }
    final resumePlayback = !reviewing && (isPlaying || resumeAfterSaving);
    if (reviewing) stopListening();
    _scrub.cancel(e, resume: false);
    e.pause();
    tick(); // Drain the last playing blocks against the old key.
    final frame = e.positionFrame;
    _beginKeyShift(target);
    try {
      final loaded = await _loadKey(e, target);
      if (_disposed) return;
      e.seekFrame(frame);
      e.flushCapture();
      _tracker?.reset();
      _endCount = e.endCount;
      if (loaded != _transpose) {
        _endRun();
        _transpose = loaded;
        scorer = PracticeScorer(reference, options: _scoringOptions())
          ..onlyLine = loopLine
          ..startPass(position, fromLine: _aimLine ?? 0);
        take = _newTake(e);
        // Keep the singer's trace at the MIDI pitches they sang. The
        // colours of those points belonged to the previous key.
        for (final (i, point) in points.indexed) {
          points[i] = UserPoint(point.time, point.midi, PitchVerdict.noReference);
        }
        lastSample = null;
        lastVoiced = null;
        finished = false;
      }
      applyMix();
      await _rememberKey();
    } catch (err) {
      if (!_disposed) error = '无法载入原调音频：$err';
    } finally {
      if (!_disposed) {
        // A route event may have arrived since the last UI frame.
        tick();
        _finishKeyShift();
        if (resumePlayback && !_suspended && pauseReason == null && error == null && frame < e.lengthFrames) {
          _play(restartAtEnd: false);
        } else {
          notifyListeners();
        }
      }
    }
  }

  /// Whether the song has an accompaniment to practise with. Without one,
  /// the original singer always plays (there would be nothing else to hear).
  bool get hasAccompaniment => meta.practiceAccompaniment != null;

  /// Re-applies volumes and scoring settings (after the user changed them).
  void applyMix() {
    final e = _engine;
    if (e == null) return;
    final kind = listening;
    e.setTrackGain(TrackSlot.accompaniment, settings.accompanimentVolume);
    // Listening back: your own voice instead of the original singer's.
    // Listening to the original: the original singer at full volume.
    e.setTrackGain(
      TrackSlot.guideVocal,
      switch (kind) {
        ListenKind.take => 0,
        ListenKind.original => 1,
        null =>
          hasAccompaniment
              ? (settings.guideVocalOn ? settings.guideVocalVolume : 0)
              : math.max(0.6, settings.guideVocalVolume),
      },
    );
    e.setTrackGain(TrackSlot.take, kind == ListenKind.take ? 1 : 0);
    _refreshMonitorRoute();
    e.setMonitorGain(_monitorEnabled && kind == null ? settings.monitorGain : 0);
    scorer.options = _scoringOptions();
    _outputRoute = _readOutputRoute();
    _systemLatency = e.systemLatencySeconds;
    _latency = _systemLatency + latencyOffsetMs / 1000.0;
    final t = _tracker;
    if (t != null) {
      t.options = t.options.copyWith(gateDb: settings.micGateDb, latencySeconds: _latency);
    }
  }

  /// Adds [text] to the native audio event log, which test builds show in
  /// 练习设置 (diagnostics for pauses nobody asked for).
  static void _log(String text) {
    final t = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    final ms = t.millisecond.toString().padLeft(3, '0');
    try {
      NativeAudio.logAudioEvent('${two(t.hour)}:${two(t.minute)}:${two(t.second)}.$ms app: $text');
    } catch (_) {}
  }

  void play() => _play();

  void _play({bool restartAtEnd = true}) {
    final e = _engine;
    if (e == null || !started || _suspended || _disposed || _calibrating || changingKey || error != null) return;
    _scrub.cancel(e, resume: false);
    _log('play at ${position.toStringAsFixed(1)} s');
    try {
      final measurement = usesMeasurementMode;
      NativeAudio.configureSession(record: true, measurement: measurement);
      final events = e.takeAudioEvents();
      if (events & AudioEvents.deviceLost != 0) _monitorEnabled = false;
      _refreshMonitorRoute();
      // The headphones went before the monitor could be turned off: not in
      // measurement mode on the speaker.
      if (usesMeasurementMode != measurement) {
        NativeAudio.configureSession(record: true, measurement: usesMeasurementMode);
      }
      e.flushCapture();
      _tracker?.reset();
      e.start();
      applyMix();
      pauseReason = null;
    } catch (err) {
      _log('play failed: $err');
      pauseReason = '音频暂时不可用，请稍后点播放重试';
      notifyListeners();
      return;
    }
    final review = _review;
    if (review != null) {
      // `position` trails `e.positionSeconds` by `_latency / 2`, so when a
      // review range runs to the end of the track `position` may stay more
      // than 0.05 s below `review.$2` even after the engine stopped there.
      if (position >= review.$2 - 0.05 || e.positionSeconds >= e.lengthSeconds - 0.05) {
        _seekEngine(review.$1);
      }
    } else if (restartAtEnd && (finished || e.positionSeconds >= e.lengthSeconds - 0.05)) {
      finished = false;
      // From the top again: another run through the song.
      if (loopLine == null) _endRun();
      seek(loopLine != null ? _loopRange(loopLine!).$1 : 0);
    }
    e.play();
    notifyListeners();
  }

  /// Plays back what the singer sang (of [line], or the whole take) with
  /// the accompaniment. Practice resumes with [stopListening].
  void listenBack({int? line}) {
    final e = _engine;
    final t = take;
    if (e == null || t == null || changingKey || !canListenBack(line: line) || _suspended) return;
    e.pause();
    final (a, b) = line != null ? _loopRange(line) : (math.max(0.0, t.startSeconds - 0.5), t.endSeconds + 0.3);
    final range = (a, math.min(b, math.max(a, duration)));
    final first = math.max(t.startFrame, (range.$1 * e.sampleRate).floor());
    final end = math.min(t.endFrame, (range.$2 * e.sampleRate).ceil());
    if (end <= first) return;
    final key = (t.version, first, end);
    if (_loadedTake != key) {
      e.loadTrackPcm(TrackSlot.take, t.readFrames(first, end), 1);
      e.setTrackOffset(TrackSlot.take, first);
      _loadedTake = key;
    }
    if (listening == ListenKind.original) {
      // Straight from the original singer: practice would have gone on at
      // the start of that line.
      _resumeLine = _originalLine;
    } else if (_review == null) {
      _resumeAt = e.positionSeconds;
      _resumeLine = null;
    }
    _review = range;
    _listenKind = ListenKind.take;
    e.setLoop(null, null);
    applyMix();
    _seekEngine(range.$1);
    play();
  }

  /// Plays [line] (by default the current one) with the original singer at
  /// full volume, nothing scored or recorded. Afterwards practice is ready
  /// at the start of that line, paused.
  void listenOriginal({int? line}) {
    final e = _engine;
    final li = line ?? currentLine;
    if (e == null || _suspended || changingKey || li < 0 || li >= reference.lines.length) return;
    if (listening == ListenKind.take) stopListening();
    e.pause();
    final (a, b) = _loopRange(li);
    final range = (a, math.min(b, math.max(a, duration)));
    _review = range;
    _listenKind = ListenKind.original;
    _originalLine = li;
    e.setLoop(null, null);
    applyMix();
    _seekEngine(range.$1);
    play();
  }

  /// Back to practising (the take stays for another listen). After the
  /// original singer, practice continues at the start of that line.
  void stopListening() {
    final e = _engine;
    if (_review == null) return;
    _scrub.cancel(e, resume: false);
    final kind = _listenKind;
    _review = null;
    _listenKind = null;
    if (e != null) {
      e.pause();
      if (kind == ListenKind.take) {
        e.unloadTrack(TrackSlot.take);
        _loadedTake = null;
      }
      _endCount = e.endCount; // reaching the end while reviewing is not a finished run
      applyMix();
      if (kind == ListenKind.original && _originalLine != null) {
        // Ready to sing the line just heard (and loop it, when looping).
        _tracker?.reset();
        setLoopLine(loopLine == null ? null : _originalLine);
        _seekBeforeLine(_originalLine!);
        return;
      }
      final line = _resumeLine;
      if (line != null) {
        _seekBeforeLine(line);
      } else {
        _seekEngine(_resumeAt);
      }
    }
    _tracker?.reset();
    setLoopLine(loopLine);
    notifyListeners();
  }

  /// Moves playback without touching the scores (used while listening back).
  void _seekEngine(double seconds) {
    final e = _engine;
    if (e == null) return;
    e.seek(Duration(microseconds: (math.max(0, seconds) * 1e6).round()));
    e.flushCapture();
    _tracker?.reset();
  }

  void pause() {
    if (isPlaying) _log('pause at ${position.toStringAsFixed(1)} s');
    _scrub.stayPaused();
    _engine?.pause();
    notifyListeners();
  }

  /// Stop the hardware too: pausing the song alone still records the mic.
  void suspend({String reason = '练习已暂停，点播放继续'}) {
    if (_engine != null) _log('suspend: $reason');
    _suspended = true;
    pauseReason = reason;
    _stopDevice();
  }

  /// Give calibration exclusive use of the microphone and output. The song
  /// stays paused afterwards, at the same position with the same take.
  Future<T> withAudioPausedForCalibration<T>(Future<T> Function() measure) async {
    // The stems are being replaced: the engine is not the practice path yet.
    if (changingKey) throw StateError('正在变调，变调完成后再测量延迟');
    _calibrating = true;
    pauseReason = '练习已暂停，点播放继续';
    try {
      _stopDevice();
      return await measure();
    } finally {
      _calibrating = false;
      if (!_disposed) {
        tick();
        applyMix();
        notifyListeners();
      }
    }
  }

  void _stopDevice() {
    final e = _engine;
    _scrub.cancel(e, resume: false);
    if (e != null) {
      e.pause();
      e.stop();
      e.flushCapture();
    }
    _tracker?.reset();
    lastSample = null;
    lastVoiced = null;
    notifyListeners();
  }

  /// Returning to the app makes playback available, without starting the mic.
  void resume() {
    _suspended = false;
    notifyListeners();
  }

  void togglePlay() => isPlaying ? pause() : play();

  bool beginScrub() => !_suspended && !changingKey && _scrub.begin(_engine);

  void updateScrub(double seconds) {
    if (!_scrub.active) return;
    _scrub.update(seconds);
    notifyListeners();
  }

  void endScrub() {
    if (!_scrub.active) return;
    _scrub.end(_engine, seek);
    notifyListeners();
  }

  void cancelScrub() {
    if (!_scrub.active) return;
    _engine?.flushCapture();
    _tracker?.reset();
    _scrub.cancel(_engine);
    notifyListeners();
  }

  /// Moves playback to [seconds]. What was sung stays until it is sung
  /// again from there.
  void seek(double seconds) => _seek(seconds);

  /// With [toLine], the jump is there to sing that line: the music before
  /// it only leads in, so the lines it belongs to are not scored and
  /// nothing is recorded until the line's own part begins.
  void _seek(double seconds, {int? toLine}) {
    final e = _engine;
    if (e == null || changingKey) return;
    if (reviewing) {
      _seekEngine(seconds);
      notifyListeners();
      return;
    }
    final to = math.max(0.0, seconds);
    e.seek(Duration(microseconds: (to * 1e6).round()));
    e.flushCapture();
    _tracker?.reset();
    scorer.startPass(to, fromLine: toLine ?? 0);
    _recordFrom = toLine == null ? 0 : lineSpan(toLine).$1;
    _aimLine = toLine;
    points.removeWhere((p) => p.time >= seconds - 0.05);
    notifyListeners();
  }

  /// To [leadIn] seconds before [line] (one by default), to sing it.
  void _seekBeforeLine(int line, {double leadIn = 1.0}) =>
      _seek(reference.lines[line].start - leadIn, toLine: line);

  (double, double) _loopRange(int line) {
    final l = reference.lines[line];
    return (math.max(0, l.start - 1.2), l.end + 0.6);
  }

  /// The part of the song that is [line]'s own: from shortly before its
  /// first character (an early entry, its consonant) to shortly after its
  /// last one, and never past the middle of the gap to the singing before
  /// and after it. The rest of what plays around a looped line belongs to
  /// the lines next to it.
  (double, double) lineSpan(int line) {
    final lines = reference.lines;
    final l = lines[line];
    var a = l.start - 0.3, b = l.end + 0.3;
    for (var i = line - 1; i >= 0; i--) {
      final notes = lines[i].notes;
      if (notes.isEmpty) continue; // a line without singing has no end to protect
      a = math.max(a, (notes.last.end + l.start) / 2);
      break;
    }
    for (var i = line + 1; i < lines.length; i++) {
      final notes = lines[i].notes;
      if (notes.isEmpty) continue;
      b = math.min(b, (l.end + notes.first.start) / 2);
      break;
    }
    return (math.max(0, math.min(a, l.start)), math.max(b, l.end));
  }

  /// What is recorded right now: one line's own part while it loops,
  /// otherwise everything from where the line jumped to begins.
  (double, double) get _recordSpan {
    final loop = loopLine;
    return loop != null ? lineSpan(loop) : (_recordFrom, double.infinity);
  }

  /// Loops one line (null = play the whole song).
  void setLoopLine(int? line) {
    if (changingKey) return;
    // Looping a line, another line, or the whole song again: a new run.
    if (line != loopLine) _endRun();
    loopLine = line;
    scorer.onlyLine = line;
    final e = _engine;
    if (e == null || reviewing) return;
    if (line == null) {
      e.setLoop(null, null);
    } else {
      final (a, b) = _loopRange(line);
      e.setLoop(a, b);
      if (position < a || position > b) seek(a);
    }
    notifyListeners();
  }

  /// To shortly before [line], to sing it; [leadIn] seconds of the music
  /// before it play first (跳过前奏 leaves time to get ready).
  void seekToLine(int line, {double leadIn = 1.0}) {
    if (line < 0 || line >= reference.lines.length) return;
    if (loopLine != null) setLoopLine(line);
    _seekBeforeLine(line, leadIn: leadIn);
  }

  /// 从头再唱: the whole song again from the top, as a new run.
  void restart() {
    if (changingKey) return;
    if (reviewing) stopListening();
    if (loopLine != null) {
      setLoopLine(null); // ends the loop's run
    } else {
      _endRun();
    }
    finished = false;
    seek(0);
    play();
  }

  /// The line 上一句, 下一句, 重唱这一句 and 单句循环 move from. While
  /// looping, the looped line, from its lead-in to its end; while hearing
  /// the original singer, the line heard; in the lead-in after jumping to a
  /// line, that line, though the line before may still be sounding.
  /// Otherwise the line last begun (the first one before it): right after
  /// singing a line, 重唱这一句 is that line again.
  int get currentLine {
    if (reference.lines.isEmpty) return -1;
    final original = originalLine;
    if (original != null) return original;
    final at = reference.lineIndexAt(position);
    if (reviewing) return at; // listening back to the take
    final loop = loopLine;
    if (loop != null) return loop;
    final aim = _aimLine;
    return aim != null && aim > at ? aim : at;
  }

  /// The line shown with its lyrics: [currentLine], except that once it is
  /// over (an interlude), the line coming up, which the countdown, 跳过间奏
  /// and 听这句原唱 are about.
  int get shownLine {
    final li = currentLine;
    if (li < 0 || reviewing || loopLine != null) return li;
    final lines = reference.lines;
    final t = position;
    if (li + 1 < lines.length && t >= lines[li].start && t > lines[li].end + lineOverSeconds) return li + 1;
    return li;
  }

  /// How long after its last character a line gives way to the next one.
  static const lineOverSeconds = 0.6;

  /// Pulls captured audio, updates pitch and scores. Call once per frame.
  void tick() {
    final e = _engine;
    final tr = _tracker;
    if (e == null || tr == null || _suspended || _calibrating) return;
    final events = e.takeAudioEvents();
    if (events != 0) _log('audio events 0x${events.toRadixString(16)}');
    if (events & AudioEvents.silencing != 0) {
      if (events & AudioEvents.deviceLost != 0) _monitorEnabled = false;
      applyMix();
      suspend(
        reason: events & AudioEvents.deviceLost != 0
            ? '耳机断开了，已暂停，免得从扬声器外放。点播放继续'
            : '声音被打断了（来电、闹钟或别的 App），点播放继续',
      );
      resume();
      return;
    }
    // iOS also reports this when playback and recording start: keep going,
    // only the new route's latency matters.
    if (events & AudioEvents.routeChanged != 0) {
      final measurement = usesMeasurementMode;
      _refreshMonitorRoute();
      if (usesMeasurementMode != measurement && pauseReason == null) {
        try {
          NativeAudio.configureSession(record: true, measurement: usesMeasurementMode);
        } catch (err) {
          _log('route session mode: $err');
        }
      }
      applyMix();
      notifyListeners(); // update an open mix sheet even while paused
    }
    if (changingKey || _scrub.active) {
      e.flushCapture();
      return;
    }
    final review = _review;
    if (review != null) {
      // The microphone would only hear the playback: nothing to score.
      e.flushCapture();
      final playing = e.isPlaying;
      // Read `endCount` after `isPlaying` (yt_audio clears playing before
      // bumping end_count) and reuse it so a stop transition is never missed.
      final endCount = e.endCount;
      final ended = endCount != _endCount;
      _endCount = endCount; // reaching the end here is not a finished run
      final atEnd = !playing && e.positionSeconds >= e.lengthSeconds - 0.05;
      if (_listenKind == ListenKind.original && (position >= review.$2 || atEnd)) {
        stopListening(); // heard the line: ready to sing it
        return;
      }
      if (playing && position >= review.$2) e.pause();
      if (playing || ended) notifyListeners();
      return;
    }
    // Playback reached the line jumped to: from here the line playing is
    // the one in focus.
    final aim = _aimLine;
    if (aim != null && reference.lineIndexAt(position) >= aim) _aimLine = null;
    var changed = false;
    final t = take;
    final latencyFrames = (_latency * e.sampleRate).round();
    // Outside this span the singer is waiting for their line (the lead-in
    // after jumping to it, the music around a looped line): what the
    // microphone hears there must not replace what was sung there before.
    final (from, to) = _recordSpan;
    final fromFrame = (from * e.sampleRate).round();
    final toFrame = to.isFinite ? (to * e.sampleRate).round() : null;
    for (final block in e.readCapture()) {
      if (block.playing) {
        t?.addAudio(block.samples, block.songFrame, latencyFrames, fromFrame: fromFrame, toFrame: toFrame);
        _runSeconds += block.samples.length / e.sampleRate;
      }
      for (final p in tr.addBlock(block.samples, block.songFrame, block.clockFrame, block.playing)) {
        final s = scorer.add(p);
        lastSample = s;
        if (p.voiced) lastVoiced = s;
        _clock = p.clockTime;
        if (p.playing) {
          // When a loop wraps, drop the old trail from the new pass's start.
          if (points.isNotEmpty && p.songTime < points.last.time - 0.25) {
            points.removeWhere((point) => point.time >= p.songTime);
          }
          final point = UserPoint(p.songTime, p.midi, s.verdict, s.deviationCents);
          points.add(point);
          if (p.songTime >= from && p.songTime < to) t?.addPoint(point);
        }
        changed = true;
      }
    }
    if (points.length > 4000) {
      final cut = points.indexWhere((p) => p.time > position - _keepSeconds);
      if (cut > 0) points.removeRange(0, cut);
    }
    if (e.endCount != _endCount) {
      _endCount = e.endCount;
      finished = true;
      changed = true;
    }
    if (changed || e.isPlaying) notifyListeners();
  }

  double get clockTime => _clock;

  /// Scores of every token sung so far (for colouring the graph).
  Map<RefToken, double> tokenScores() {
    final out = <RefToken, double>{};
    final p = position;
    for (final line in scorer.results()) {
      if (line.line.start > p) break;
      for (final t in line.tokens) {
        if (t.attempted && !t.score.isNaN && t.token.end < p) {
          out[t.token] = t.score;
        }
      }
    }
    return out;
  }

  /// The current run as a record: the lines sung in it and their scores, or
  /// null when nothing was sung in it yet.
  PracticeRecord? _runRecord() {
    final results = scorer.results();
    final lines = [
      for (final i in scorer.sungLines.toList()..sort())
        if (results[i].attempted) i,
    ];
    if (lines.isEmpty) return null;
    final sung = [for (final i in lines) results[i]];
    // Played is not sung: the scorer takes a line as attempted once it has
    // played. A run in which no voice was heard on its notes (listening,
    // a silent microphone) is not a practice run to keep.
    if (!sung.any((r) => r.tokens.any((t) => t.attempted && t.coverage > 0))) return null;
    var at = _runAt;
    if (at == null) {
      // The time identifies the record: no two runs share one.
      at = DateTime.now();
      if (!at.isAfter(_lastRunAt)) at = _lastRunAt.add(const Duration(microseconds: 1));
      _runAt = _lastRunAt = at;
    }
    final total = scorer.scoredSeconds;
    final seconds = sung.fold<double>(0, (a, r) => a + r.sungSeconds);
    return PracticeRecord(
      at: at,
      score: scorer.overallScore(sung),
      lineScores: {for (final i in lines) i: results[i].score},
      loopLine: loopLine,
      transpose: _transpose,
      durationSeconds: _runSeconds,
      coverage: total > 0 ? (seconds / total).clamp(0.0, 1.0).toDouble() : 0,
    );
  }

  /// Ends the current run; what is sung from now on is a new one. The run
  /// is kept as it is now and stored with the next [save].
  void _endRun() {
    final record = _runRecord();
    if (record != null) _endedRuns.add(record);
    _runAt = null;
    _runSeconds = 0;
    scorer.sungLines.clear();
  }

  /// Stores this session's runs in the song's history: one record per run,
  /// however often this is called. A run that was stored before and went on
  /// is updated; lines sung in an earlier run are not stored again with a
  /// later one. Returns the newest record, or null when nothing was sung.
  Future<PracticeRecord?> save() {
    final done = _saving.then((_) async {
      final current = _runRecord();
      final records = [..._endedRuns, ?current];
      if (records.isEmpty) return _stored;
      await repository.savePractice(meta.id, records);
      _endedRuns.removeWhere(records.contains);
      return _stored = records.last;
    });
    _saving = done.then((_) {}, onError: (_) {});
    return done;
  }

  @override
  void dispose() {
    _disposed = true;
    final e = _engine;
    _scrub.cancel(e, resume: false);
    _engine = null;
    if (e != null) {
      try {
        e.stop();
      } catch (_) {}
      e.dispose();
    }
    super.dispose();
  }
}


Future<void> _loadInBackground(
  PracticeEngine e,
  int slot,
  ShiftedTrack track,
  void Function(double)? onProgress,
) async {
  if (onProgress == null) {
    await e.loadTrackPcmInBackground(slot, track.decode);
    return;
  }
  final progress = ReceivePort()..listen((value) => onProgress(value as double));
  try {
    await e.loadTrackPcmInBackground(slot, _decodeWithProgress(track, progress.sendPort));
  } finally {
    progress.close();
  }
}

// Capture only sendable values in the closure that goes to the worker.
DecodedAudio Function() _decodeWithProgress(ShiftedTrack track, SendPort progress) =>
    () => track.decode(onProgress: progress.send);
