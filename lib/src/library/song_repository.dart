import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
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
        out.add(SongMeta.fromJson(jsonDecode(await f.readAsString()) as Map<String, dynamic>));
      } catch (_) {
        // Skip broken entries (e.g. an interrupted import).
      }
    }
    out.sort((a, b) => b.createdAt.compareTo(a.createdAt));
    return out;
  }

  Future<SongMeta> load(String id) async => SongMeta.fromJson(
      jsonDecode(await File(pathFor(id, songFile)).readAsString()) as Map<String, dynamic>);

  Future<void> save(SongMeta meta) async {
    dirFor(meta.id).createSync(recursive: true);
    await _writeAtomic(pathFor(meta.id, songFile), jsonEncode(meta.toJson()));
  }

  Future<SongReference> loadReference(String id) async => SongReference.fromJson(
      jsonDecode(await File(pathFor(id, referenceFile)).readAsString()) as Map<String, dynamic>);

  Future<void> saveReference(String id, SongReference ref) {
    _melodyCache.remove(id);
    return _writeAtomic(pathFor(id, referenceFile), jsonEncode(ref.toJson()));
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

  Future<List<PracticeRecord>> loadHistory(String id) async {
    final f = File(pathFor(id, historyFile));
    if (!f.existsSync()) return [];
    final list = jsonDecode(await f.readAsString()) as List;
    return [for (final e in list) PracticeRecord.fromJson(e as Map<String, dynamic>)];
  }

  /// Appends a practice result and updates the song's statistics.
  Future<SongMeta> addPractice(String id, PracticeRecord record, {int keep = 200}) async {
    final history = await loadHistory(id);
    history.add(record);
    if (history.length > keep) history.removeRange(0, history.length - keep);
    await _writeAtomic(pathFor(id, historyFile), jsonEncode([for (final r in history) r.toJson()]));
    final meta = await load(id);
    meta.practiceCount++;
    meta.lastPracticedAt = record.at;
    if (record.loopLine == null) {
      meta.lastScore = record.score;
      if (meta.bestScore == null || record.score > meta.bestScore!) meta.bestScore = record.score;
    }
    await save(meta);
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
    await _writeAtomic('${takesDir(songId).path}/${r.id}.json', jsonEncode(r.toJson()));
  }

  Future<void> deleteRecording(String songId, Recording r) async {
    for (final path in [recordingPath(songId, r), '${takesDir(songId).path}/${r.id}.json']) {
      final f = File(path);
      if (f.existsSync()) await f.delete();
    }
  }

  Future<void> delete(String id) async {
    _melodyCache.remove(id);
    final d = dirFor(id);
    if (d.existsSync()) await d.delete(recursive: true);
  }

  Future<void> _writeAtomic(String path, String content) async {
    final tmp = File('$path.tmp');
    await tmp.writeAsString(content, flush: true);
    await tmp.rename(path);
  }
}

const _magic = 0x54505459; // "YTPT"

/// Binary pitch track: magic, version, hop (f64), frames, midi[f32], level[f32].
Uint8List encodePitchTrack(PitchTrack t) {
  final n = t.length;
  final b = ByteData(4 + 4 + 8 + 4 + n * 8);
  b.setUint32(0, _magic, Endian.little);
  b.setUint32(4, 1, Endian.little);
  b.setFloat64(8, t.hopSeconds, Endian.little);
  b.setUint32(16, n, Endian.little);
  var o = 20;
  for (var i = 0; i < n; i++, o += 4) {
    b.setFloat32(o, t.midi[i], Endian.little);
  }
  for (var i = 0; i < n; i++, o += 4) {
    b.setFloat32(o, t.rmsDb[i], Endian.little);
  }
  return b.buffer.asUint8List();
}

PitchTrack decodePitchTrack(Uint8List bytes) {
  final b = ByteData.sublistView(bytes);
  if (b.getUint32(0, Endian.little) != _magic) {
    throw const FormatException('not a YinTrace pitch file');
  }
  final hop = b.getFloat64(8, Endian.little);
  final n = b.getUint32(16, Endian.little);
  final midi = Float32List(n), db = Float32List(n);
  var o = 20;
  for (var i = 0; i < n; i++, o += 4) {
    midi[i] = b.getFloat32(o, Endian.little);
  }
  for (var i = 0; i < n; i++, o += 4) {
    db[i] = b.getFloat32(o, Endian.little);
  }
  return PitchTrack(hopSeconds: hop, midi: midi, rmsDb: db, aperiodicity: Float32List(n));
}
