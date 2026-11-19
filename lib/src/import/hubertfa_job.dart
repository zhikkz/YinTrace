import 'dart:isolate';
import 'dart:typed_data';

import 'package:flutter/services.dart';

import '../analysis/hubertfa_aligner.dart';
import '../analysis/lrc.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../audio/audio_backend.dart';
import '../dsp/swift_f0.dart';
import '../models/pitch_model.dart';
import '../separation/onnx_model.dart';
import '../separation/tensor_model.dart';

/// Aligns [lines] to the song's stored vocal with HuBERTFA, in the
/// background. With [pitchModelPath], the vocal's pitch is measured again
/// first and the song is aligned on it: a song imported with an older
/// version of the app, or from a song file, has the pitch curve that version
/// measured. The new curve comes back with the reference (null when it was
/// not measured, or the model failed and [track] was used).
Future<(SongReference, PitchTrack?)> alignStoredVocal(
  String modelPath,
  String vocalPath,
  PitchTrack track,
  List<LyricLine> lines, {
  required Map<(int, int), double> pins,
  required Map<(int, int), String> readings,
  String? pitchModelPath,
  void Function(int, int)? onProgress,
  bool Function()? isCancelled,
}) async {
  final events = ReceivePort();
  events.listen((message) {
    final (done, total, reply) = message as (int, int, SendPort);
    onProgress?.call(done, total);
    reply.send(isCancelled?.call() ?? false);
  });
  try {
    return await _alignWholeSong(modelPath, vocalPath, track, lines, pins, readings, pitchModelPath, events.sendPort);
  } finally {
    events.close();
  }
}

// Only send model inputs and a port across isolates. The UI owns the
// progress and cancellation callbacks, and may already have been disposed.
Future<(SongReference, PitchTrack?)> _alignWholeSong(
  String modelPath,
  String vocalPath,
  PitchTrack track,
  List<LyricLine> lines,
  Map<(int, int), double> pins,
  Map<(int, int), String> readings,
  String? pitchModelPath,
  SendPort events,
) => _inBackground(modelPath, vocalPath, lines, (aligner, vocal) async {
  PitchTrack? measured;
  if (pitchModelPath != null) {
    TensorModel? model;
    try {
      model = await OnnxTensorModel.load(
        pitchModelPath,
        inputName: PitchModel.inputName,
        outputName: PitchModel.outputName,
      );
      measured = await analyzePitchWithModel(vocal, HubertFaAligner.sampleRate, SwiftF0(model));
    } catch (_) {
      // Aligned on the stored curve, as before.
    } finally {
      try {
        await model?.close();
      } catch (_) {}
    }
  }
  final reference = await aligner.alignSong(vocal, measured ?? track, lines, pins: pins, readings: readings,
      onProgress: (done, total) async {
    final reply = ReceivePort();
    try {
      events.send((done, total, reply.sendPort));
      if (await reply.first == true) throw const SeparationCancelled();
    } finally {
      reply.close();
    }
  });
  return (reference, measured);
});

Future<SongReference> alignStoredLine(
  String modelPath,
  String vocalPath,
  PitchTrack track,
  LyricLine line,
  SongReference current,
  int index, {
  required Map<int, double> pins,
  required Map<int, String> readings,
  required Set<int> restore,
  LyricLine? next,
}) => _inBackground(modelPath, vocalPath, [line, ?next], (aligner, vocal) {
  return aligner.editLine(
    vocal, track, line, current, index, pins: pins, readings: readings, restore: restore, next: next,
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
