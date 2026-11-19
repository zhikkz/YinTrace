import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/atomic_file.dart';
import 'recording.dart';
import 'song.dart';

/// Stores songs on the device, one directory per song:
///
/// ```
/// songs/<id>/song.json         metadata + lyrics
/// songs/<id>/reference.json    per-character melody (lines/tokens/notes)
/// songs/<id>/pitch.bin         vocal pitch contour
/// songs/<id>/vocals.m4a        separated lead vocal (guide track)
/// songs/<id>/accompaniment.m4a karaoke track (original minus lead vocal)
/// songs/<id>/original.<ext>    the imported file
/// songs/<id>/history.json      practice results
/// songs/<id>/takes/<take>.m4a  recordings the singer kept (+ <take>.json)
/// ```
class SongRepository {
  SongRepository(this.root);

  final Directory root;

  static const songFile = 'song.json';
  static const referenceFile = 'reference.json';
  static const pitchFile = 'pitch.bin';
  static const historyFile = 'history.json';
  static const _practiceJournal = 'practice.pending.json';
  static final _songOperations = <String, Future<void>>{};

  // Queue readers and writers for a song, including a retry after a failed
  // write. Other songs can still load and save independently.
  Future<T> _withSong<T>(String id, Future<T> Function() operation, {bool recover = true}) {
    final key = dirFor(id).absolute.path;
    final previous = _songOperations[key] ?? Future<void>.value();
    final result = previous.then((_) async {
      final journal = File(pathFor(id, _practiceJournal));
      if (recover && journal.existsSync()) {
        final pending = jsonDecode(await journal.readAsString()) as Map<String, dynamic>;
        await _finishPractice(id, pending);
      }
      return operation();
    });
    final next = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    _songOperations[key] = next;
    return result.whenComplete(() {
      if (identical(_songOperations[key], next)) _songOperations.remove(key);
    });
  }

  // Both values are absolute snapshots. Replaying after either rename is
  // idempotent, including when the last step (deleting the journal) failed.
  Future<void> _finishPractice(String id, Map<String, dynamic> pending) async {
    await writeFileAtomic(pathFor(id, historyFile), jsonEncode(pending['history']));
    await writeFileAtomic(pathFor(id, songFile), jsonEncode(pending['song']));
    await File(pathFor(id, _practiceJournal)).delete();
  }

  Directory dirFor(String id) => Directory('${root.path}/$id');
  String pathFor(String id, String file) => '${root.path}/$id/$file';

  /// Creates a new, empty song directory and returns its id.
  String newSongId() {
    final now = DateTime.now();
    final rnd = math.Random().nextInt(1 << 32).toRadixString(16).padLeft(8, '0');
    final id = '${now.millisecondsSinceEpoch.toRadixString(36)}-$rnd';
    dirFor(id).createSync(recursive: true);
    return id;
  }

  Future<List<SongMeta>> list() async {
    if (!root.existsSync()) return [];
    final out = <SongMeta>[];
    for (final e in root.listSync()) {
      if (e is! Directory) continue;
      final f = File('${e.path}/$songFile');
      if (!f.existsSync()) continue;
      try {
        out.add(await load(e.path.split(Platform.pathSeparator).last));
      } catch (_) {
        // Skip broken entries (e.g. an interrupted import).
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<SongMeta> load(String id) => _withSong(id, () => _readSong(id));

  Future<SongMeta> _readSong(String id) async => SongMeta.fromJson(
      jsonDecode(await File(pathFor(id, songFile)).readAsString()) as Map<String, dynamic>);

  /// Saves metadata and keeps the stored practice statistics of an existing song.
  Future<void> save(SongMeta meta) => _withSong(meta.id, () async {
    dirFor(meta.id).createSync(recursive: true);
    final path = pathFor(meta.id, songFile);
    final data = meta.toJson();
    if (File(path).existsSync()) {
      final current = (await _readSong(meta.id)).toJson();
      for (final field in const ['practiceCount', 'bestScore', 'lastScore', 'lastPracticedAt']) {
        data.remove(field);
        if (current.containsKey(field)) data[field] = current[field];
      }
    }
    await writeFileAtomic(path, jsonEncode(data));
  });

  Future<SongReference> loadReference(String id) async => SongReference.fromJson(
      jsonDecode(await File(pathFor(id, referenceFile)).readAsString()) as Map<String, dynamic>);

  Future<void> saveReference(String id, SongReference ref) {
    _melodyCache.remove(id);
    return writeFileAtomic(pathFor(id, referenceFile), jsonEncode(ref.toJson()));
  }

  final _melodyCache = <String, List<(double, double, double)>>{};

  /// (start, end, midi) of every reference note, for the library's melody
  /// fingerprints. Cached per song.
  Future<List<(double, double, double)>> loadMelody(String id) async {
    final cached = _melodyCache[id];
    if (cached != null) return cached;
    try {
      final ref = await loadReference(id);
      final notes = [for (final n in ref.notes) (n.start, n.end, n.midi)];
      _melodyCache[id] = notes;
      return notes;
    } catch (_) {
      return const [];
    }
  }

  Future<void> savePitchTrack(String id, PitchTrack track) async {
    await File(pathFor(id, pitchFile)).writeAsBytes(encodePitchTrack(track), flush: true);
  }

  Future<PitchTrack> loadPitchTrack(String id) async =>
      decodePitchTrack(await File(pathFor(id, pitchFile)).readAsBytes());

  Future<List<PracticeRecord>> loadHistory(String id) => _withSong(id, () => _readHistory(id));

  Future<List<PracticeRecord>> _readHistory(String id) async {
    final f = File(pathFor(id, historyFile));
    if (!f.existsSync()) return [];
    final list = jsonDecode(await f.readAsString()) as List;
    final history = [for (final e in list) PracticeRecord.fromJson(e as Map<String, dynamic>)];
    await _estimateCoverage(id, history);
    return history;
  }

  /// Records from before runs stored how much of the song they cover (and
  /// records stored without it) get an estimate from the lines they list,
  /// so that a run of one line no longer counts as the whole song.
  Future<void> _estimateCoverage(String id, List<PracticeRecord> history) async {
    if (history.every((r) => r.coverage != null)) return;
    final SongReference ref;
    try {
      ref = await loadReference(id);
    } catch (_) {
      return; // no reference to measure against: they stay as they are
    }
    for (final r in history) {
      r.coverage ??= ref.coverageOf(r.lineScores.keys);
    }
  }

  Future<void> _writeHistory(String id, List<PracticeRecord> history) =>
      writeFileAtomic(pathFor(id, historyFile), jsonEncode([for (final r in history) r.toJson()]));

  /// Stores a practice run and updates the song's statistics.
  Future<SongMeta> addPractice(String id, PracticeRecord record, {int keep = 200}) =>
      savePractice(id, [record], keep: keep);

  /// Stores practice runs, oldest first, and updates the song's statistics.
  /// A run that is already in the history (same [PracticeRecord.at]: its
  /// scores were looked at before, and it went on) is replaced; a new one is
  /// added and counts as one more practice.
  ///
  /// The best score is the best run through the whole song
  /// ([PracticeRecord.wholeSong]) in the history.
  Future<SongMeta> savePractice(String id, List<PracticeRecord> records, {int keep = 200}) =>
      _withSong(id, () => _savePractice(id, records, keep));

  Future<SongMeta> _savePractice(String id, List<PracticeRecord> records, int keep) async {
    final history = await _readHistory(id);
    var added = 0;
    for (final record in records) {
      final i = history.indexWhere((r) => r.key == record.key);
      if (i >= 0) {
        history[i] = record;
      } else {
        history.add(record);
        added++;
      }
    }
    await _estimateCoverage(id, history);
    // Once the history was cut, an older and better run may be gone from it.
    final complete = history.length < keep;
    if (history.length > keep) history.removeRange(0, history.length - keep);
    final meta = await _readSong(id);
    meta.practiceCount += added;
    for (final record in records) {
      final last = meta.lastPracticedAt;
      if (last == null || record.at.isAfter(last)) meta.lastPracticedAt = record.at;
    }
    final whole = [
      for (final r in history)
        if (r.wholeSong && !r.score.isNaN) r.score,
    ];
    if (whole.isNotEmpty) meta.lastScore = whole.last;
    final best = whole.isEmpty ? null : whole.reduce(math.max);
    final before = meta.bestScore;
    meta.bestScore = complete || before == null || (best != null && best > before) ? best : before;
    final pending = {'history': [for (final r in history) r.toJson()], 'song': meta.toJson()};
    await writeFileAtomic(pathFor(id, _practiceJournal), jsonEncode(pending));
    await _finishPractice(id, pending);
    return meta;
  }

  Directory takesDir(String id) => Directory('${root.path}/$id/takes');
  String recordingPath(String songId, Recording r) => '${takesDir(songId).path}/${r.file}';

  /// The recordings kept for a song, newest first.
  Future<List<Recording>> loadRecordings(String id) async {
    final dir = takesDir(id);
    if (!dir.existsSync()) return [];
    final out = <Recording>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.endsWith('.json')) continue;
      try {
        final r = Recording.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
        if (File(recordingPath(id, r)).existsSync()) out.add(r);
      } catch (_) {
        // Skip a broken entry.
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<void> saveRecording(String songId, Recording r) async {
    takesDir(songId).createSync(recursive: true);
    await writeFileAtomic('${takesDir(songId).path}/${r.id}.json', jsonEncode(r.toJson()));
  }

  Future<void> deleteRecording(String songId, Recording r) async {
    for (final path in [recordingPath(songId, r), '${takesDir(songId).path}/${r.id}.json']) {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    }
  }

  /// After the lyrics were re-aligned: moves the line scores of the
  /// practice history to where their lines are now (see
  /// [PracticeRecord.remapped]). [old] is the reference the history was
  /// recorded against, [lineMap] where each of its lines went.
  Future<void> remapHistory(String id, SongReference old, Map<int, int> lineMap) =>
      _withSong(id, () => _remapHistory(id, old, lineMap));

  Future<void> _remapHistory(String id, SongReference old, Map<int, int> lineMap) async {
    final f = File(pathFor(id, historyFile));
    if (!f.existsSync()) return;
    final list = jsonDecode(await f.readAsString()) as List;
    final history = [for (final e in list) PracticeRecord.fromJson(e as Map<String, dynamic>)];
    bool stays(int line) => lineMap[line] == line;
    if (history.every((r) => r.lineScores.keys.every(stays) && (r.loopLine == null || stays(r.loopLine!)))) return;
    // How much of the song an old run covered is measured against the
    // lyrics it was sung to, before lines of it are dropped.
    for (final r in history) {
      r.coverage ??= old.coverageOf(r.lineScores.keys);
    }
    await _writeHistory(id, [for (final r in history) ?r.remapped(lineMap)]);
  }

  Future<void> delete(String id) => _withSong(id, () async {
    _melodyCache.remove(id);
    final d = dirFor(id);
    if (d.existsSync()) await d.delete(recursive: true);
  }, recover: false);
}

const _magic = 0x54505459; // "YTPT"

/// Binary pitch track: magic, version, hop (f64), frames, midi[f32],
/// level[f32], and from version 2 on spectral change[f32]. Older versions
/// of the app read a version 2 file as version 1.
Uint8List encodePitchTrack(PitchTrack t) {
  final n = t.length;
  final change = t.spectralChange;
  final b = ByteData(4 + 4 + 8 + 4 + n * (change == null ? 8 : 12));
  b.setUint32(0, _magic, Endian.little);
  b.setUint32(4, change == null ? 1 : 2, Endian.little);
  b.setFloat64(8, t.hopSeconds, Endian.little);
  b.setUint32(16, n, Endian.little);
  var o = 20;
  for (final values in [t.midi, t.rmsDb, ?change]) {
    for (var i = 0; i < n; i++, o += 4) {
      b.setFloat32(o, values[i], Endian.little);
    }
  }
  return b.buffer.asUint8List();
}

PitchTrack decodePitchTrack(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  if (bytes.length < 20 || b.getUint32(0, Endian.little) != _magic) {
    throw const FormatException('not a YinTrace pitch file');
  }
  final version = b.getUint32(4, Endian.little);
  final hop = b.getFloat64(8, Endian.little);
  final n = b.getUint32(16, Endian.little);
  if (version != 1 && version != 2) throw const FormatException('unsupported pitch track version');
  if (!hop.isFinite || hop <= 0) throw const FormatException('invalid pitch frame interval');
  final bytesPerFrame = version == 2 ? 12 : 8;
  if (bytes.length != 20 + n * bytesPerFrame) throw const FormatException('invalid pitch track length');

  Float32List read(int at) {
    final out = Float32List(n);
    for (var i = 0, o = at; i < n; i++, o += 4) {
      out[i] = b.getFloat32(o, Endian.little);
    }
    return out;
  }

  return PitchTrack(
    hopSeconds: hop,
    midi: read(20),
    rmsDb: read(20 + n * 4),
    aperiodicity: Float32List(n),
    spectralChange: version == 2 ? read(20 + n * 8) : null,
  );
}
