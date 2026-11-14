import 'dart:isolate';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/settings.dart';
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

/// Drives one practice run: audio engine, live pitch tracking and scoring.
class PracticeSession extends ChangeNotifier {
  PracticeSession({
    required this.meta,
    required this.reference,
    required this.repository,
    required this.settings,
    this.contour,
    this.loopLine,
    PracticeEngine Function()? engineFactory,
    this.decodeInBackground = true,
  }) : _engineFactory = engineFactory ?? (() => PracticeEngine.create(mode: EngineMode.duplex)) {
    scorer = PracticeScorer(reference, options: _scoringOptions());
  }

  final SongMeta meta;
  final SongReference reference;
  final SongRepository repository;
  final AppSettings settings;
  final PitchTrack? contour;
  final PracticeEngine Function() _engineFactory;

  /// Decode the tracks in a background isolate (keeps the UI responsive).
  final bool decodeInBackground;

  /// When set, the run loops this line.
  int? loopLine;

  late PracticeScorer scorer;
  PracticeEngine? _engine;
  LivePitchTracker? _tracker;
  int _endCount = 0;
  double _latency = 0;
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
  bool _disposed = false;
  bool _suspended = false;
  String? pauseReason;

  /// What the singer sang in this session (null until the audio started).
  TakeRecorder? take;

  /// The song time span being played back, while listening back.
  (double, double)? _review;
  ListenKind? _listenKind;
  int? _originalLine; // the line played with the original singer
  double _resumeAt = 0; // where practice continues after listening back
  int _loadedTake = -1; // version of the take in the engine's take slot

  PracticeEngine? get engine => _engine;
  bool get isPlaying => _engine?.isPlaying ?? false;

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
    final (a, b) = _loopRange(line);
    return t.covers(a, b);
  }

  /// The singer's pitch trail to draw: live while practising, the recorded
  /// one while listening back to it.
  List<UserPoint> get displayPoints => listening == ListenKind.take ? take!.points : points;

  /// While listening back: what the singer sang at the current position.
  UserPoint? get reviewPoint => listening == ListenKind.take ? take?.pointAt(position) : null;

  /// Total compensation applied to captured audio (seconds).
  double get latency => _latency;

  /// Song position the singer currently hears.
  double get position {
    final e = _engine;
    if (e == null) return 0;
    return math.max(0, e.positionSeconds - _latency / 2);
  }

  double get duration => math.max(meta.duration, _engine?.lengthSeconds ?? 0);

  ScoringOptions _scoringOptions() => ScoringOptions(
    greatCents: settings.toleranceCents.toDouble(),
    okCents: settings.toleranceCents * 2.0,
    octaveTolerant: settings.octaveTolerant,
  );

  /// Opens the audio device and loads the tracks.
  Future<void> start() async {
    if (started) return;
    try {
      final perm = await NativeAudio.requestMicPermission();
      if (_disposed) return;
      if (perm != MicPermission.granted) {
        error = '没有麦克风权限：请在 系统设置 → 隐私与安全性 → 麦克风 中允许 YinTrace';
        notifyListeners();
        return;
      }
      NativeAudio.configureSession(record: true, measurement: settings.measurementMode);
      final e = _engineFactory();
      _engine = e;
      final acc = meta.accompanimentFile ?? meta.originalFile;
      final tracks = <int, String>{
        if (acc != null) TrackSlot.accompaniment: repository.pathFor(meta.id, acc),
        TrackSlot.guideVocal: repository.pathFor(meta.id, meta.vocalsFile),
      };
      for (final entry in tracks.entries) {
        if (decodeInBackground) {
          final path = entry.value;
          final rate = e.sampleRate;
          final audio = await Isolate.run(() => NativeAudio.decodeFile(path, sampleRate: rate));
          if (_engine != e) return; // disposed while loading
          e.loadTrackPcm(entry.key, audio.samples, audio.channels);
        } else {
          e.loadTrackFile(entry.key, entry.value);
        }
      }
      applyMix();
      final period = e.periodFrames / e.sampleRate;
      _latency = NativeAudio.sessionLatency + period + settings.latencyOffsetMs / 1000.0;
      _tracker = LivePitchTracker(
        sampleRate: e.sampleRate,
        options: LivePitchOptions(gateDb: settings.micGateDb, latencySeconds: _latency),
      );
      take = TakeRecorder(
        sampleRate: e.sampleRate,
        lengthFrames: math.max(e.lengthFrames, (meta.duration * e.sampleRate).ceil()),
      );
      _endCount = e.endCount;
      if (_suspended || pauseReason != null) {
        // Backgrounding and returning while decode is still in flight must
        // not reopen the microphone before the user resumes.
        e.stop();
        e.flushCapture();
      } else {
        e.start();
      }
      started = true;
      if (loopLine != null) {
        setLoopLine(loopLine);
      }
      notifyListeners();
    } catch (err) {
      if (_disposed) return;
      error = '无法启动音频：$err';
      notifyListeners();
    }
  }

  /// Re-applies volumes and scoring settings (after the user changed them).
  void applyMix() {
    final e = _engine;
    if (e == null) return;
    final hasAcc = meta.accompanimentFile != null || meta.originalFile != null;
    final kind = listening;
    e.setTrackGain(TrackSlot.accompaniment, settings.accompanimentVolume);
    // Listening back: your own voice instead of the original singer's.
    // Listening to the original: the original singer at full volume.
    e.setTrackGain(
      TrackSlot.guideVocal,
      switch (kind) {
        ListenKind.take => 0,
        ListenKind.original => 1,
        null => hasAcc ? settings.guideVocalVolume : math.max(0.6, settings.guideVocalVolume),
      },
    );
    e.setTrackGain(TrackSlot.take, kind == ListenKind.take ? 1 : 0);
    scorer.options = _scoringOptions();
    final t = _tracker;
    if (t != null) {
      final period = e.periodFrames / e.sampleRate;
      _latency = NativeAudio.sessionLatency + period + settings.latencyOffsetMs / 1000.0;
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

  void play() {
    final e = _engine;
    if (e == null || _suspended || _disposed) return;
    _log('play at ${position.toStringAsFixed(1)} s');
    try {
      NativeAudio.configureSession(record: true, measurement: settings.measurementMode);
      e.takeAudioEvents();
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
      if (position >= review.$2 - 0.05) _seekEngine(review.$1);
    } else if (finished || e.positionSeconds >= e.lengthSeconds - 0.05) {
      finished = false;
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
    if (e == null || t == null || !canListenBack(line: line) || _suspended) return;
    e.pause();
    if (_loadedTake != t.version) {
      e.loadTrackPcm(TrackSlot.take, t.samples!, 1);
      _loadedTake = t.version;
    }
    final range = line != null ? _loopRange(line) : (math.max(0.0, t.startSeconds - 0.5), t.endSeconds + 0.3);
    if (listening == ListenKind.original) stopListening();
    if (_review == null) _resumeAt = e.positionSeconds;
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
    if (e == null || _suspended || li < 0 || li >= reference.lines.length) return;
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
    final kind = _listenKind;
    _review = null;
    _listenKind = null;
    if (e != null) {
      e.pause();
      if (kind == ListenKind.take) {
        e.unloadTrack(TrackSlot.take);
        _loadedTake = -1;
      }
      applyMix();
      if (kind == ListenKind.original && _originalLine != null) {
        _tracker?.reset();
        setLoopLine(loopLine);
        seek(math.max(0, reference.lines[_originalLine!].start - 1.0));
        return;
      }
      _seekEngine(_resumeAt);
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
    _engine?.pause();
    notifyListeners();
  }

  /// Stop the hardware too: pausing the song alone still records the mic.
  void suspend({String reason = '练习已暂停，点播放继续'}) {
    if (_engine != null) _log('suspend: $reason');
    _suspended = true;
    pauseReason = reason;
    final e = _engine;
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

  void seek(double seconds) {
    final e = _engine;
    if (e == null) return;
    if (reviewing) {
      _seekEngine(seconds);
      notifyListeners();
      return;
    }
    e.seek(Duration(microseconds: (math.max(0, seconds) * 1e6).round()));
    e.flushCapture();
    _tracker?.reset();
    scorer.resetFrom(math.max(0, seconds));
    points.removeWhere((p) => p.time >= seconds - 0.05);
    notifyListeners();
  }

  (double, double) _loopRange(int line) {
    final l = reference.lines[line];
    return (math.max(0, l.start - 1.2), l.end + 0.6);
  }

  /// Loops one line (null = play the whole song).
  void setLoopLine(int? line) {
    loopLine = line;
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

  void seekToLine(int line) {
    if (line < 0 || line >= reference.lines.length) return;
    if (loopLine != null) setLoopLine(line);
    seek(math.max(0, reference.lines[line].start - 1.0));
  }

  int get currentLine => reference.lineIndexAt(position);

  /// Pulls captured audio, updates pitch and scores. Call once per frame.
  void tick() {
    final e = _engine;
    final tr = _tracker;
    if (e == null || tr == null || _suspended) return;
    final events = e.takeAudioEvents();
    if (events != 0) _log('audio events 0x${events.toRadixString(16)}');
    if (events & AudioEvents.silencing != 0) {
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
    if (events & AudioEvents.routeChanged != 0) applyMix();
    final review = _review;
    if (review != null) {
      // The microphone would only hear the playback: nothing to score.
      e.flushCapture();
      _endCount = e.endCount; // reaching the end here is not a finished run
      final atEnd = !e.isPlaying && e.positionSeconds >= e.lengthSeconds - 0.05;
      if (_listenKind == ListenKind.original && (position >= review.$2 || atEnd)) {
        stopListening(); // heard the line: ready to sing it
        return;
      }
      if (e.isPlaying && position >= review.$2) e.pause();
      if (e.isPlaying || position >= review.$2) notifyListeners();
      return;
    }
    var changed = false;
    final t = take;
    final latencyFrames = (_latency * e.sampleRate).round();
    for (final block in e.readCapture()) {
      if (block.playing) t?.addAudio(block.samples, block.songFrame, latencyFrames);
      for (final p in tr.addBlock(block.samples, block.songFrame, block.clockFrame, block.playing)) {
        final s = scorer.add(p);
        lastSample = s;
        if (p.voiced) lastVoiced = s;
        _clock = p.clockTime;
        if (p.playing) {
          final point = UserPoint(p.songTime, p.midi, s.verdict, s.deviationCents);
          points.add(point);
          t?.addPoint(point);
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

  /// Stores the run in the song's history. Returns null when nothing was
  /// sung.
  Future<PracticeRecord?> save({double? elapsedSeconds}) async {
    final results = scorer.results();
    final lines = <int, double>{
      for (var i = 0; i < results.length; i++)
        if (results[i].attempted) i: results[i].score,
    };
    if (lines.isEmpty) return null;
    final record = PracticeRecord(
      at: DateTime.now(),
      score: scorer.overallScore(results),
      lineScores: lines,
      loopLine: loopLine,
      durationSeconds: elapsedSeconds ?? 0,
    );
    await repository.addPractice(meta.id, record);
    return record;
  }

  @override
  void dispose() {
    _disposed = true;
    final e = _engine;
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
