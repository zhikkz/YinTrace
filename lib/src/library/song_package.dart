import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

import '../analysis/reference.dart';
import '../app/licenses.dart' show appVersion;
import 'song.dart';
import 'song_repository.dart';

/// A song as one file, to give to someone else: what the song plays (the
/// separated vocal, the accompaniment), its lyrics and its melody as the
/// sender corrected it. The receiver imports it and practises right away,
/// without separating anything.
///
/// What the sender did with the song stays with the sender: the practice
/// history, the scores and the recordings are not in the file.
///
/// ```
/// "YinTraceSong"            12 bytes
/// container version (u32)   little endian, 1
/// manifest length (u32)     little endian
/// manifest                  UTF-8 JSON: the song and its files
/// the files                 one after the other, in the manifest's order
/// ```
const songPackageExtension = 'yintrace';

class SongPackageException implements Exception {
  SongPackageException(this.message);
  final String message;
  @override
  String toString() => message;
}

const _magic = 'YinTraceSong';
const _version = 1;
const _headerBytes = 20;
const _maxManifestBytes = 8 << 20;
const _chunk = 1 << 20;

/// File name of the package of [meta]: `歌名 - 歌手.yintrace`.
String songPackageName(SongMeta meta) {
  String clean(String s) => s.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
  final title = clean(meta.title);
  final artist = clean(meta.artist);
  return '${title.isEmpty ? '未命名' : title}${artist.isEmpty ? '' : ' - $artist'}.$songPackageExtension';
}

/// Top level, so the isolates' closures capture only these arguments.
Future<void> exportSongPackageInBackground(String songsRoot, String id, String outputPath) =>
    Isolate.run(() => exportSongPackageSync(songsRoot, id, outputPath));

Future<SongMeta> importSongPackageInBackground(String songsRoot, String packagePath) =>
    Isolate.run(() => importSongPackageSync(songsRoot, packagePath));

/// Writes song [id] of the library at [songsRoot] to [outputPath],
/// replacing a file that is there. Synchronous: run it in an isolate.
void exportSongPackageSync(String songsRoot, String id, String outputPath) {
  final repo = SongRepository(Directory(songsRoot));
  final tmp = File('$outputPath.tmp');
  try {
    final meta = SongMeta.fromJson(
      jsonDecode(File(repo.pathFor(id, SongRepository.songFile)).readAsStringSync()) as Map<String, dynamic>,
    );
    final parts = [
      ('reference', SongRepository.referenceFile),
      ('pitch', SongRepository.pitchFile),
      ('vocals', meta.vocalsFile),
      if (meta.accompanimentFile case final name?)
        ('accompaniment', name)
      // Songs from early versions kept the imported file; it is what plays
      // where there is no accompaniment, and is not used otherwise.
      else if (meta.originalFile case final name?)
        ('original', name),
    ];
    final files = <Map<String, dynamic>>[];
    for (final (role, name) in parts) {
      final file = File(repo.pathFor(id, name));
      if (!file.existsSync()) throw SongPackageException('这首歌的文件不全，导出不了');
      files.add({'role': role, 'name': name, 'bytes': file.lengthSync(), 'sha256': _hash(file)});
    }
    final manifest = utf8.encode(
      jsonEncode({
        'format': 'yintrace-song-package',
        'version': _version,
        'app': appVersion,
        'song': {
          'title': meta.title,
          'artist': meta.artist,
          'duration': meta.duration,
          'lyrics': meta.lyrics,
          'separated': meta.separated,
          // Which models separated it; not how fast the sender's device is.
          'modelInfo': {
            for (final key in const ['mdx', 'vr', 'alignment']) key: ?meta.modelInfo[key],
          },
        },
        'files': files,
      }),
    );
    final out = tmp.openSync(mode: FileMode.write);
    try {
      final head = ByteData(_headerBytes);
      head.buffer.asUint8List().setRange(0, _magic.length, ascii.encode(_magic));
      head.setUint32(12, _version, Endian.little);
      head.setUint32(16, manifest.length, Endian.little);
      out.writeFromSync(head.buffer.asUint8List());
      out.writeFromSync(manifest);
      for (final entry in files) {
        final source = File(repo.pathFor(id, entry['name'] as String)).openSync();
        try {
          // The file as it was measured: the editor may have saved since.
          final digest = _copy(source, out, entry['bytes'] as int);
          if (digest != entry['sha256'] || source.positionSync() != source.lengthSync()) {
            throw SongPackageException('这首歌刚刚改动过，请再导出一次');
          }
        } finally {
          source.closeSync();
        }
      }
      out.flushSync();
    } finally {
      out.closeSync();
    }
    tmp.renameSync(outputPath);
  } catch (e) {
    if (tmp.existsSync()) tmp.deleteSync();
    throw _readable(e, '这首歌的数据读不出来，导出不了');
  }
}

/// Adds the song in the package at [packagePath] to the library at
/// [songsRoot] as a new song that was never practised, and returns it.
/// Synchronous: run it in an isolate.
SongMeta importSongPackageSync(String songsRoot, String packagePath) {
  const incomplete = '这个歌曲文件不完整，可能没有传完，请让对方重新发一次';
  final repo = SongRepository(Directory(songsRoot));
  String? id;
  RandomAccessFile? input;
  try {
    final length = File(packagePath).lengthSync();
    input = File(packagePath).openSync();
    final head = input.readSync(_headerBytes);
    if (head.length < _headerBytes || ascii.decode(head.sublist(0, _magic.length), allowInvalid: true) != _magic) {
      throw SongPackageException('这不是音迹导出的歌曲文件');
    }
    final numbers = ByteData.sublistView(head);
    if (numbers.getUint32(12, Endian.little) > _version) {
      throw SongPackageException('这个歌曲文件是更新版本的音迹导出的，请先更新 App');
    }
    final manifestBytes = numbers.getUint32(16, Endian.little);
    if (manifestBytes > _maxManifestBytes) throw const FormatException('manifest too long');
    if (_headerBytes + manifestBytes > length) throw SongPackageException(incomplete);
    final manifest = jsonDecode(utf8.decode(input.readSync(manifestBytes))) as Map<String, dynamic>;
    if (manifest['format'] != 'yintrace-song-package') throw const FormatException('not a song package');
    final files = [for (final f in manifest['files'] as List) (f as Map).cast<String, dynamic>()];
    var total = _headerBytes + manifestBytes;
    for (final f in files) {
      final bytes = f['bytes'] as int;
      if (bytes < 0) throw const FormatException('negative size');
      total += bytes;
    }
    if (total != length) throw SongPackageException(incomplete);

    id = repo.newSongId();
    // Role -> name in the song's folder. Names are the app's own: nothing
    // of a name in the file is used but the extension of an audio file.
    final stored = <String, String>{};
    for (final f in files) {
      final role = f['role'] as String;
      final bytes = f['bytes'] as int;
      final name = switch (role) {
        'reference' => SongRepository.referenceFile,
        'pitch' => SongRepository.pitchFile,
        'vocals' || 'accompaniment' || 'original' => '$role${_extension(f['name'] as String)}',
        _ => null, // from a newer version: not needed here
      };
      if (name == null) {
        input.setPositionSync(input.positionSync() + bytes);
        continue;
      }
      if (stored.containsKey(role)) throw const FormatException('a file twice');
      final out = File(repo.pathFor(id, name)).openSync(mode: FileMode.write);
      final String digest;
      try {
        digest = _copy(input, out, bytes);
      } finally {
        out.closeSync();
      }
      if (digest != f['sha256']) throw SongPackageException('这个歌曲文件损坏了，请让对方重新发一次');
      stored[role] = name;
    }
    if (!stored.containsKey('reference') || !stored.containsKey('pitch') || !stored.containsKey('vocals')) {
      throw const FormatException('a file is missing');
    }
    // What the song page reads: better refused now than a song that does
    // not open.
    SongReference.fromJson(
      jsonDecode(File(repo.pathFor(id, SongRepository.referenceFile)).readAsStringSync()) as Map<String, dynamic>,
    );
    decodePitchTrack(File(repo.pathFor(id, SongRepository.pitchFile)).readAsBytesSync());

    final song = (manifest['song'] as Map).cast<String, dynamic>();
    final duration = (song['duration'] as num).toDouble();
    if (!duration.isFinite || duration <= 0) throw const FormatException('no duration');
    final title = (song['title'] as String? ?? '').trim();
    final meta = SongMeta(
      id: id,
      title: title.isEmpty ? '未命名歌曲' : title,
      artist: (song['artist'] as String? ?? '').trim(),
      createdAt: DateTime.now(),
      duration: duration,
      lyrics: song['lyrics'] as String? ?? '',
      vocalsFile: stored['vocals']!,
      accompanimentFile: stored['accompaniment'],
      originalFile: stored['original'],
      separated: song['separated'] as bool? ?? true,
      modelInfo: (song['modelInfo'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
    );
    // Last: a folder without it is not a song (see SongRepository.list).
    final songFile = repo.pathFor(id, SongRepository.songFile);
    File('$songFile.tmp').writeAsStringSync(jsonEncode(meta.toJson()), flush: true);
    File('$songFile.tmp').renameSync(songFile);
    return meta;
  } catch (e) {
    if (id != null && repo.dirFor(id).existsSync()) repo.dirFor(id).deleteSync(recursive: true);
    throw _readable(e, '这个歌曲文件读不出来，可能已经损坏');
  } finally {
    input?.closeSync();
  }
}

/// The error to show for [e]: its own message, "no space left", or
/// [otherwise] for content that is not what it should be.
SongPackageException _readable(Object e, String otherwise) {
  if (e is SongPackageException) return e;
  if (e is FileSystemException) {
    // ENOSPC is 28 on iOS, macOS, Android and Linux.
    return SongPackageException(e.osError?.errorCode == 28 ? '存储空间不足，请腾出一些空间后重试' : '读写文件失败：${e.message}');
  }
  return SongPackageException(otherwise);
}

/// ".m4a" of "vocals.m4a"; nothing for a name without a plain extension.
String _extension(String name) => RegExp(r'\.[A-Za-z0-9]{1,5}$').stringMatch(name)?.toLowerCase() ?? '';

String _hash(File file) {
  final input = file.openSync();
  try {
    return _copy(input, null, input.lengthSync());
  } finally {
    input.closeSync();
  }
}

/// Copies the next [bytes] bytes of [from] to [to] (or nowhere) and returns
/// their SHA-256.
String _copy(RandomAccessFile from, RandomAccessFile? to, int bytes) {
  final digest = _DigestSink();
  final hasher = sha256.startChunkedConversion(digest);
  final buffer = Uint8List(_chunk);
  var left = bytes;
  while (left > 0) {
    final n = from.readIntoSync(buffer, 0, left < _chunk ? left : _chunk);
    if (n <= 0) throw const FormatException('unexpected end of file');
    final piece = Uint8List.sublistView(buffer, 0, n);
    hasher.add(piece);
    to?.writeFromSync(piece);
    left -= n;
  }
  hasher.close();
  return digest.value.toString();
}

class _DigestSink implements Sink<Digest> {
  late Digest value;
  @override
  void add(Digest data) => value = data;
  @override
  void close() {}
}
