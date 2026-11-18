import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../analysis/hubertfa_aligner.dart';
import '../analysis/lrc.dart';
import '../analysis/lyrics_language.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../audio/audio_backend.dart';

Future<SongReference> alignStoredVocal(
  String modelPath,
  String vocalPath,
  PitchTrack track,
  List<LyricLine> lines, {
  required Map<(int, int), double> pins,
  required Map<(int, int), String> readings,
}) => _inBackground(modelPath, vocalPath, lines, (aligner, vocal) {
  return aligner.alignSong(vocal, track, lines, pins: pins, readings: readings);
});

Future<RefLine> alignStoredLine(
  String modelPath,
  String vocalPath,
  PitchTrack track,
  LyricLine line,
  int index,
  LyricsLanguage language, {
  required double lower,
  required double upper,
  required Map<int, double> pins,
  required Map<int, String> readings,
}) => _inBackground(modelPath, vocalPath, [line], (aligner, vocal) {
  return aligner.alignEditedLine(
    vocal,
    track,
    line,
    index,
    language,
    lower: lower,
    upper: upper,
    pins: pins,
    readings: readings,
  );
});

Future<T> _inBackground<T>(
  String modelPath,
  String vocalPath,
  List<LyricLine> lines,
  Future<T> Function(HubertFaAligner aligner, Float32List vocal) run,
) {
  final token = RootIsolateToken.instance;
  if (token == null) throw StateError('Lyric alignment must be started from the root isolate');
  return Isolate.run(() async {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
    final vocal = const NativeAudioBackend()
        .decode(vocalPath, sampleRate: HubertFaAligner.sampleRate, channels: 1)
        .samples;
    return HubertFaAligner.withModel(modelPath, lines, (aligner) => run(aligner, vocal));
  });
}
