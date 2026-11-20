import 'dart:async';
import 'dart:isolate';

import 'package:flutter/foundation.dart';

import '../analysis/lrc.dart';
import '../analysis/manual_timing.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../import/hubertfa_job.dart';
import '../library/song.dart';
import '../library/song_repository.dart';

typedef TimingRetimer = Future<SongReference> Function(
  PitchTrack track,
  List<LyricLine> lines,
  SongReference current,
  int line,
  Map<int, double> pins,
);

/// [retimeLine] off the UI isolate, with only the alignment inputs captured.
Future<SongReference> retimeLineInBackground(
  PitchTrack track,
  List<LyricLine> lines,
  SongReference current,
  int line,
  Map<int, double> pins,
) => Isolate.run(() => retimeLine(track, lines, current, line, pins));

/// Owns one song's edits and continues aligning and saving after the editor closes.
class PitchCorrectionSession extends ChangeNotifier {
  PitchCorrectionSession({required this.songId, required this._songs, this._alignInBackground = true, this._retimer}) {
    unawaited(_load());
  }

  final String songId;
  final SongRepository _songs;
  final bool _alignInBackground;
  final TimingRetimer? _retimer;
  SongMeta? _meta;
  SongReference? _reference;
  PitchTrack? _track;
  String? _loadError;
  String? _notice;
  int _noticeRevision = 0;
  String? _lastFailure;
  int _failureRevision = 0;
  int _revision = 0;
  int _savedRevision = 0;
  bool _loading = true;
  bool _editingLine = false;
  int _retimesQueued = 0;
  int _writes = 0;
  int _modelJobs = 0;
  List<LyricLine>? _lyricLines;

  /// Latest requested pins, including requests waiting for the tap window.
  final _wanted = <int, Map<int, double>>{};
  final _pending = <int, String?>{};
  static const _nudgeWindow = Duration(milliseconds: 250);
  Timer? _nudgeTimer;
  Future<void> _retimeQueue = Future.value();
  Future<void> _saving = Future.value();
  Future<void>? _alignmentWrite;

  SongReference? get reference => _reference;
  PitchTrack? get track => _track;
  String? get loadError => _loadError;
  int get revision => _revision;
  int get savedRevision => _savedRevision;
  String? get notice => _notice;
  int get noticeRevision => _noticeRevision;
  String? get lastFailure => _lastFailure;
  int get failureRevision => _failureRevision;
  bool get editingLine => _editingLine;
  bool get aligningTiming => _retimesQueued > 0;
  bool get timingBusy => _pending.isNotEmpty || aligningTiming;
  bool get busy => _loading || editingLine || timingBusy || _writes > 0;
  bool get usingModel => _modelJobs > 0 || _pending.values.any((path) => path != null);

  bool get usesHubertFa =>
      _meta?.modelInfo['alignment'] == 'HuBERTFA' ||
      (_reference?.lines.any((line) => line.hubertFa || line.tokens.any((t) => t.pinyinOverride != null)) ?? false);

  // HuBERTFA carries pitch edits into the alignment it starts with.
  bool get canEditPitch => !editingLine && (!aligningTiming || !usesHubertFa);

  Map<int, double> pendingPins(int line) => _wanted[line] ?? const {};

  double startOf(int line, int token) => _wanted[line]?[token] ?? _reference!.lines[line].tokens[token].slotStart;

  List<LyricLine> get _lines => _lyricLines ??= linesOfReference(_reference!, _meta!.lyrics);

  LyricLine lyricLine(int line) => _lines[line];

  Future<void> _load() async {
    try {
      final meta = await _songs.load(songId);
      final reference = await _songs.loadReference(songId);
      try {
        _track = await _songs.loadPitchTrack(songId);
      } catch (_) {
        // Drawn without the original singer's contour.
      }
      _meta = meta;
      _reference = reference;
    } catch (error) {
      _loadError = '$error';
    } finally {
      _loading = false;
      notifyListeners();
    }
  }

  String get vocalPath => _songs.pathFor(songId, _meta!.vocalsFile);

  Map<int, double> _pinsOfLine(int line) => {for (final (i, t) in _reference!.lines[line].tokens.indexed) i: ?t.pinned};

  Map<int, String> _readings(int line) => {
    for (final (i, t) in _reference!.lines[line].tokens.indexed) i: ?t.pinyinOverride,
  };

  void _report(String text, {bool failure = false}) {
    _notice = text;
    _noticeRevision++;
    if (failure) {
      _lastFailure = text;
      _failureRevision++;
    }
    notifyListeners();
  }

  Future<void> changePitch(int line, int token, void Function(RefToken) edit) async {
    if (!canEditPitch) return;
    // Apply this edit to the reference chosen by any in-flight alignment
    // write. Keep counting the edit as pending if the editor closes meanwhile.
    if (_alignmentWrite case final write?) {
      _writes++;
      await write;
      _writes--;
    }
    final ref = _reference!;
    edit(ref.lines[line].tokens[token]);
    _revision++;
    await _save(ref);
  }

  /// Queues writes and publishes a new alignment only once it is on disk.
  Future<void> _save(SongReference ref, {bool commitAlignment = false}) {
    _writes++;
    final write = _saving.then((_) async {
      try {
        await _songs.saveReference(songId, ref);
        if (commitAlignment) {
          _reference = ref;
          _revision++;
        }
        _savedRevision++;
      } catch (error) {
        _report('没能保存：$error', failure: true);
      } finally {
        if (commitAlignment) _alignmentWrite = null;
        _writes--;
        notifyListeners();
      }
    });
    _saving = write;
    if (commitAlignment) _alignmentWrite = write;
    notifyListeners();
    return write;
  }

  void setStart(int line, int token, double seconds, {required bool nudge, String? modelPath}) {
    final ref = _reference;
    if (editingLine || ref == null || _track == null) return;
    if (usesHubertFa && modelPath == null && _retimer == null) return;
    final (lo, hi) = pinRange(ref, line, token, lineOnly: usesHubertFa, pendingPins: _wanted);
    final pin = seconds.clamp(lo, hi).toDouble();
    if ((pin - startOf(line, token)).abs() < 0.002) {
      final unit = ref.language.unit;
      _report(seconds < pin ? '再往前就碰到前面的$unit了' : '再往后就碰到后面的$unit了');
      return;
    }
    _wanted[line] = Map.unmodifiable({...(_wanted[line] ?? _pinsOfLine(line)), token: pin});
    _pending[line] = modelPath;
    notifyListeners();
    _nudgeTimer?.cancel();
    if (nudge) {
      _nudgeTimer = Timer(_nudgeWindow, flushNudges);
    } else {
      flushNudges();
    }
  }

  void flushNudges() {
    _nudgeTimer?.cancel();
    _nudgeTimer = null;
    final pending = Map<int, String?>.of(_pending);
    _pending.clear();
    for (final MapEntry(:key, :value) in pending.entries) {
      unawaited(_retime(key, _wanted[key]!, modelPath: value));
    }
  }

  /// Runs ready timing edits on the latest completed alignment. A new tap
  /// supersedes older edits to the same line, including results in flight.
  Future<void> _retime(int line, Map<int, double> pins, {String? modelPath}) {
    _wanted[line] = pins;
    _retimesQueued++;
    if (modelPath != null) _modelJobs++;
    final work = _retimeQueue.then((_) async {
      bool isCurrent() => identical(_wanted[line], pins);
      try {
        if (!isCurrent()) return;
        if (usesHubertFa) {
          await _updateModelLine(
            line,
            pins: pins,
            readings: _readings(line),
            modelPath: modelPath,
            isCurrent: isCurrent,
          );
        } else {
          await _retimeNow(line, pins, isCurrent);
        }
      } catch (error) {
        if (isCurrent()) _report('没能重新对齐：$error', failure: true);
      } finally {
        if (isCurrent()) _wanted.remove(line);
        _retimesQueued--;
        if (modelPath != null) _modelJobs--;
        notifyListeners();
      }
    });
    _retimeQueue = work;
    notifyListeners();
    return work;
  }

  Future<void> _retimeNow(int line, Map<int, double> pins, bool Function() isCurrent) async {
    final ref = _reference!, track = _track;
    if (track == null) return;
    final fresh =
        await (_retimer?.call(track, _lines, ref, line, pins) ??
            (_alignInBackground
                ? retimeLineInBackground(track, _lines, ref, line, pins)
                : Future.value(retimeLine(track, _lines, ref, line, pins))));
    if (!isCurrent()) return;
    if (pins.keys.any((i) => fresh.lines[line].tokens[i].pinned == null)) {
      _report('这里放不下，没有改', failure: true);
      return;
    }
    fresh.applyCorrectionsFrom(_reference!);
    await _save(fresh, commitAlignment: true);
  }

  Future<void> restoreLine(int line, {String? modelPath}) async {
    if (editingLine || timingBusy) return;
    final ref = _reference!;
    final tokens = ref.lines[line].tokens;
    if (modelPath != null) {
      await _editModel(line, modelPath, pins: {}, readings: {}, restore: tokens.asMap().keys.toSet());
      return;
    }
    final moved = tokens.any((token) => token.pinned != null);
    for (final token in tokens) {
      token.restore();
    }
    _revision++;
    final saved = _save(ref);
    if (moved) await _retime(line, const {});
    await saved;
  }

  Future<void> restoreToken(int line, int token, {String? modelPath}) async {
    if (editingLine || timingBusy) return;
    if (modelPath != null) {
      await _editModel(
        line,
        modelPath,
        pins: _pinsOfLine(line)..remove(token),
        readings: _readings(line)..remove(token),
        restore: {token},
      );
      return;
    }
    final moved = _reference!.lines[line].tokens[token].pinned != null;
    final saved = changePitch(line, token, (token) => token.restore());
    if (moved) await _retime(line, _pinsOfLine(line));
    await saved;
  }

  Future<void> editReading(int line, int token, String? reading, String modelPath) async {
    if (editingLine || timingBusy) return;
    final readings = _readings(line);
    if (reading == null) {
      readings.remove(token);
    } else {
      readings[token] = reading;
    }
    await _editModel(line, modelPath, pins: _pinsOfLine(line), readings: readings);
  }

  Future<void> _editModel(
    int line,
    String modelPath, {
    required Map<int, double> pins,
    required Map<int, String> readings,
    Set<int> restore = const {},
  }) async {
    _editingLine = true;
    _modelJobs++;
    notifyListeners();
    try {
      await _updateModelLine(line, pins: pins, readings: readings, modelPath: modelPath, restore: restore);
    } catch (error) {
      _report('没能重新对齐：$error', failure: true);
    } finally {
      _modelJobs--;
      _editingLine = false;
      notifyListeners();
    }
  }

  Future<void> _updateModelLine(
    int line, {
    required Map<int, double> pins,
    required Map<int, String> readings,
    required String? modelPath,
    Set<int> restore = const {},
    bool Function()? isCurrent,
  }) async {
    final track = _track;
    if (track == null) {
      _report('读不到原唱的音高曲线，不能重新对齐', failure: true);
      return;
    }
    await _saving;
    if (isCurrent?.call() == false) return;
    final ref = _reference!;
    final lines = _lines;
    final retimer = isCurrent == null ? null : _retimer;
    final fresh =
        await (retimer?.call(track, lines, ref, line, pins) ??
            alignStoredLine(
              modelPath!,
              vocalPath,
              track,
              lines[line],
              ref,
              line,
              pins: pins,
              readings: readings,
              restore: restore,
              next: line + 1 < lines.length ? lines[line + 1] : null,
            ));
    if (isCurrent?.call() == false) return;
    await _save(fresh, commitAlignment: true);
  }
}
