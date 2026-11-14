import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/audio_backend.dart';
import '../library/recording.dart';
import 'mixdown.dart';
import '../library/song_repository.dart';
import '../practice/take_recorder.dart';

/// Keeps what the singer sang in [take] as a recording of [songId]: the
/// sung part, with a little room on both sides, as a mono audio file in the
/// song's takes folder (AAC where available), encoded in the background.
Future<Recording> keepTake(
  SongRepository repo,
  String songId,
  TakeRecorder take, {
  double? score,
  AudioBackend audio = const NativeAudioBackend(),
  bool background = true,
}) async {
  final samples = take.samples;
  if (samples == null) throw StateError('nothing was recorded');
  final sr = take.sampleRate;
  final a = math.max(0, ((take.startSeconds - 0.2) * sr).round());
  final b = math.min(samples.length, ((take.endSeconds + 0.2) * sr).round());
  final part = Float32List.sublistView(samples, a, math.max(a, b));
  final now = DateTime.now();
  final id = 'take-${now.millisecondsSinceEpoch.toRadixString(36)}';
  final dir = repo.takesDir(songId)..createSync(recursive: true);
  final base = '${dir.path}/$id';
  final path = background ? await _encodeInBackground(audio, base, part, sr) : _encode(audio, base, part, sr);
  final recording = Recording(
    id: id,
    createdAt: now,
    file: path.split('/').last,
    start: a / sr,
    duration: part.length / sr,
    score: score,
    // Sang most of the song: a finished track of all of it; a few lines:
    // just those.
    mix: MixSettings(wholeSong: part.length >= 0.5 * take.lengthFrames),
  );
  await repo.saveRecording(songId, recording);
  return recording;
}

String _encode(AudioBackend audio, String base, Float32List pcm, int sr) =>
    audio.writeCompressed(base, pcm, 1, sr, bitrate: 160000);

/// Top level, so the isolate's closure captures only these arguments.
Future<String> _encodeInBackground(AudioBackend audio, String base, Float32List pcm, int sr) {
  final data = TransferableTypedData.fromList([pcm]);
  return Isolate.run(() => _encode(audio, base, data.materialize().asFloat32List(), sr));
}

/// A file name for an export: the song's title (without characters file
/// systems reject), "我的演唱" and the date, e.g. `夜航 - 我的演唱 2026-11-14 1820`.
String exportName(String title, DateTime at) {
  final clean = title.replaceAll(RegExp(r'[\\/:*?"<>|\n\r\t]'), ' ').trim();
  String two(int v) => v.toString().padLeft(2, '0');
  final date = '${at.year}-${two(at.month)}-${two(at.day)} ${two(at.hour)}${two(at.minute)}';
  return '${clean.isEmpty ? '未命名' : clean} - 我的演唱 $date';
}
