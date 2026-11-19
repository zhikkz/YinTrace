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
    scorer = PracticeScorer(reference, options: _scoringOptions())..onlyLine = loopLine;
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
  bool get isPlaying => _engine?.isPlaying ?? false;

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
    _monitorEnabled = enabled && _monitorAvailable;
    applyMix();
    notifyListeners();
  }

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
        error = '没有麦克风权限：请在 系统设置 → 隐私与安全性 → 麦克风 中允许音迹';
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

  /// Whether the song has an accompaniment to practise with. Without one,
  /// the original singer always plays (there would be nothing else to hear).
  bool get hasAccompaniment => meta.accompanimentFile != null || meta.originalFile != null;

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
    e.setMonitorGain(_monitorEnabled && kind == null ? settings.monitorVolume : 0);
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
      final events = e.takeAudioEvents();
      if (events & AudioEvents.deviceLost != 0) _monitorEnabled = false;
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
    } else if (finished || e.positionSeconds >= e.lengthSeconds - 0.05) {
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
    if (e == null || t == null || !canListenBack(line: line) || _suspended) return;
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

  /// Moves playback to [seconds]. What was sung stays until it is sung
  /// again from there.
  void seek(double seconds) => _seek(seconds);

  /// With [toLine], the jump is there to sing that line: the music before
  /// it only leads in, so the lines it belongs to are not scored and
  /// nothing is recorded until the line's own part begins.
  void _seek(double seconds, {int? toLine}) {
    final e = _engine;
    if (e == null) return;
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
    if (e == null || tr == null || _suspended) return;
    final events = e.takeAudioEvents();
    if (events != 0) _log('audio events 0x${events.toRadixString(16)}');
    if (events & AudioEvents.silencing != 0) {
      if (events & AudioEvents.deviceLost != 0) _monitorEnabled = false;
      _refreshMonitorRoute();
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
      applyMix();
      notifyListeners(); // update an open mix sheet even while paused
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
