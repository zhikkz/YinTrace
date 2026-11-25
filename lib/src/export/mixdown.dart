import 'dart:async';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import '../audio/audio_backend.dart';
import '../audio/key_shift_cache.dart';
import '../audio/shifted_track.dart';
import '../dsp/reverb.dart';
import '../library/song.dart';

/// How a recording is mixed into a finished track.
class MixSettings {
  MixSettings({
    this.vocal = 1.0,
    this.accompaniment = 0.8,
    this.reverb = 0.3,
    this.offsetMs = 0,
    this.wholeSong = true,
    this.vocalOnly = false,
    this.transpose = 0,
  });

  /// Gain of the singer's voice (0..1.5).
  double vocal;

  /// Gain of the accompaniment (0..1.5).
  double accompaniment;

  /// Amount of reverb on the voice (0..1).
  double reverb;

  /// Moves the voice against the accompaniment (positive: later).
  double offsetMs;

  /// The whole song, or only the part around the singing.
  bool wholeSong;

  /// Only the voice (with its reverb), no accompaniment.
  bool vocalOnly;

  /// Key in which the singer recorded the take.
  final int transpose;

  MixSettings copy() => MixSettings.fromJson(toJson());

  Map<String, dynamic> toJson() => {
    'vocal': vocal,
    'accompaniment': accompaniment,
    'reverb': reverb,
    'offsetMs': offsetMs,
    'wholeSong': wholeSong,
    'vocalOnly': vocalOnly,
    if (transpose != 0) 'transpose': transpose,
  };

  factory MixSettings.fromJson(Map<String, dynamic> j) => MixSettings(
    vocal: (j['vocal'] as num?)?.toDouble() ?? 1.0,
    accompaniment: (j['accompaniment'] as num?)?.toDouble() ?? 0.8,
    reverb: (j['reverb'] as num?)?.toDouble() ?? 0.3,
    offsetMs: (j['offsetMs'] as num?)?.toDouble() ?? 0,
    wholeSong: j['wholeSong'] as bool? ?? true,
    vocalOnly: j['vocalOnly'] as bool? ?? false,
    transpose: readTranspose(j['transpose']),
  );

  /// Gain of the dry voice (a little less of it as reverb is added).
  double get dryGain => vocal * (1 - 0.2 * reverb);

  /// Gain of the reverb signal (calibrated so that 1.0 is a big room).
  double get wetGain => vocal * reverb * 1.6;
}

/// Seconds of reverb ring-out rendered after the voice.
const reverbTail = 2.5;

/// The song-time span a mix covers: the whole song, or from shortly before
/// the singing to shortly after it (with room for the reverb tail).
(double, double) mixRange({
  required double takeStart,
  required double takeEnd,
  required double songDuration,
  required bool wholeSong,
}) {
  if (wholeSong && songDuration > 0) return (0, math.max(songDuration, takeEnd));
  final end = songDuration > 0 ? math.min(songDuration, takeEnd + 3) : takeEnd + 3;
  return (math.max(0, takeStart - 2), math.max(end, takeEnd + 0.5));
}

/// The reverb of a voice (wet only), stereo interleaved, [reverbTail]
/// seconds longer than the voice.
Float32List renderReverb(Float32List voice, {int sampleRate = 44100}) {
  final tail = (reverbTail * sampleRate).round();
  final l = Float32List(voice.length + tail), r = Float32List(voice.length + tail);
  Reverb(sampleRate: sampleRate).process(voice, l, r, tail: tail);
  final out = Float32List(l.length * 2);
  for (var i = 0; i < l.length; i++) {
    out[2 * i] = l[i];
    out[2 * i + 1] = r[i];
  }
  return out;
}

/// Mixes the singer's [voice] (mono, starting at song time [voiceStart])
/// over the [accompaniment] (from song time 0) into interleaved stereo for
/// the song time [from]..[to]. Fades in when it starts inside the song and
/// fades out when it stops before the end, and keeps the peak below
/// clipping.
Float32List renderMix({
  required Float32List voice,
  required double voiceStart,
  Float32List? accompaniment,
  int accompanimentChannels = 2,
  required MixSettings settings,
  required double from,
  required double to,
  double songDuration = 0,
  int sampleRate = 44100,
  void Function(double)? onProgress,
}) {
  final frames = math.max(0, ((to - from) * sampleRate).round());
  final out = Float32List(frames * 2);
  final first = (from * sampleRate).round();
  // Accompaniment.
  final acc = accompaniment;
  if (acc != null && !settings.vocalOnly && settings.accompaniment > 0) {
    final ch = accompanimentChannels;
    final g = settings.accompaniment;
    final accFrames = acc.length ~/ ch;
    for (var i = 0; i < frames; i++) {
      final f = first + i;
      if (f >= accFrames) break;
      if (ch == 1) {
        final v = acc[f] * g;
        out[2 * i] += v;
        out[2 * i + 1] += v;
      } else {
        out[2 * i] += acc[2 * f] * g;
        out[2 * i + 1] += acc[2 * f + 1] * g;
      }
    }
  }
  onProgress?.call(0.15);
  // The voice, where it was sung (plus the user's alignment).
  final at = ((voiceStart + settings.offsetMs / 1000) * sampleRate).round() - first;
  final dry = settings.dryGain;
  for (var k = 0; k < voice.length; k++) {
    final i = at + k;
    if (i < 0) continue;
    if (i >= frames) break;
    final v = voice[k] * dry;
    out[2 * i] += v;
    out[2 * i + 1] += v;
  }
  onProgress?.call(0.25);
  if (settings.reverb > 0) {
    final wet = renderReverb(voice, sampleRate: sampleRate);
    onProgress?.call(0.85);
    final g = settings.wetGain;
    final n = wet.length ~/ 2;
    for (var k = 0; k < n; k++) {
      final i = at + k;
      if (i < 0) continue;
      if (i >= frames) break;
      out[2 * i] += wet[2 * k] * g;
      out[2 * i + 1] += wet[2 * k + 1] * g;
    }
  }
  // Fades where the mix cuts into the song.
  if (from > 0.05) _fade(out, 0, (0.3 * sampleRate).round(), fadeIn: true);
  if (songDuration <= 0 || to < songDuration - 0.05) {
    final len = (2.0 * sampleRate).round();
    _fade(out, math.max(0, frames - len), frames, fadeIn: false);
  }
  // Keep the peak below clipping.
  var peak = 0.0;
  for (final v in out) {
    final a = v.abs();
    if (a > peak) peak = a;
  }
  if (peak > 0.97) {
    final k = 0.97 / peak;
    for (var i = 0; i < out.length; i++) {
      out[i] *= k;
    }
  }
  onProgress?.call(0.9);
  return out;
}

void _fade(Float32List stereo, int a, int b, {required bool fadeIn}) {
  final n = b - a;
  if (n <= 0) return;
  for (var i = 0; i < n; i++) {
    final x = (i + 0.5) / n;
    final g = fadeIn ? x * x : (1 - x) * (1 - x);
    stereo[2 * (a + i)] *= g;
    stereo[2 * (a + i) + 1] *= g;
  }
}

/// Everything a background export needs (all sendable to an isolate).
class ExportJob {
  ExportJob({
    required this.voicePath,
    required this.voiceStart,
    required this.accompanimentPath,
    required this.songDuration,
    required this.settings,
    required this.outputBase,
    this.keyShiftCache,
  });

  final String voicePath;
  final double voiceStart;
  final String? accompanimentPath;
  final double songDuration;
  final MixSettings settings;
  final KeyShiftCache? keyShiftCache;

  /// Output path without extension (.m4a where AAC is available, else .wav).
  final String outputBase;

  Map<String, dynamic> toMessage() => {
    'voice': voicePath,
    'start': voiceStart,
    'acc': accompanimentPath,
    'keyShiftCache': keyShiftCache,
    'duration': songDuration,
    'settings': settings.toJson(),
    'out': outputBase,
  };
}

/// Decodes, mixes and encodes [job] in a background isolate. Returns the
/// path written; reports progress 0..1.
Future<String> runExport(ExportJob job, {void Function(double)? onProgress}) async {
  final port = ReceivePort();
  final exit = ReceivePort();
  final errors = ReceivePort();
  final done = Completer<String>();
  port.listen((m) {
    if (m is double) {
      onProgress?.call(m);
    } else if (m is String && !done.isCompleted) {
      done.complete(m);
    }
  });
  errors.listen((e) {
    if (!done.isCompleted) done.completeError(ExportException('$e'));
  });
  exit.listen((_) {
    if (!done.isCompleted) done.completeError(ExportException('导出意外中止'));
  });
  await Isolate.spawn(_exportMain, (port.sendPort, job.toMessage()), onError: errors.sendPort, onExit: exit.sendPort);
  try {
    return await done.future;
  } finally {
    port.close();
    exit.close();
    errors.close();
  }
}

class ExportException implements Exception {
  ExportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Decodes the same accompaniment for the live preview and the export.
Float32List decodeMixAccompaniment(
  String path,
  int transpose, {
  KeyShiftCache? cache,
  void Function(double)? onProgress,
}) {
  if (transpose == 0) return const NativeAudioBackend().decode(path).samples;
  return ShiftedTrack(path, transpose, cache: cache).decode(onProgress: onProgress).samples;
}

/// The mix of [job], done on the calling isolate (used by [runExport]).
String exportNow(Map<String, dynamic> job, {void Function(double)? onProgress}) {
  const sr = 44100;
  const audio = NativeAudioBackend();
  final settings = MixSettings.fromJson(job['settings'] as Map<String, dynamic>);
  final voice = audio.decode(job['voice'] as String, sampleRate: sr, channels: 1).samples;
  onProgress?.call(0.05);
  final accPath = job['acc'] as String?;
  final acc = accPath == null || settings.vocalOnly
      ? null
      : decodeMixAccompaniment(
          accPath,
          settings.transpose,
          cache: job['keyShiftCache'] as KeyShiftCache?,
          onProgress: (f) => onProgress?.call(0.05 + 0.1 * f),
        );
  onProgress?.call(0.15);
  final voiceStart = (job['start'] as num).toDouble();
  final duration = (job['duration'] as num).toDouble();
  final (from, to) = mixRange(
    takeStart: voiceStart,
    takeEnd: voiceStart + voice.length / sr,
    songDuration: duration,
    wholeSong: settings.wholeSong,
  );
  final mix = renderMix(
    voice: voice,
    voiceStart: voiceStart,
    accompaniment: acc,
    settings: settings,
    from: from,
    // The voice alone over the whole song is a stem that lines up with the
    // song in another app; only the sung part ends with its reverb.
    to: settings.vocalOnly && !settings.wholeSong ? math.min(to, voiceStart + voice.length / sr + reverbTail) : to,
    songDuration: duration,
    sampleRate: sr,
    onProgress: (f) => onProgress?.call(0.15 + f * 0.7),
  );
  final path = audio.writeCompressed(job['out'] as String, mix, 2, sr, bitrate: 256000);
  onProgress?.call(1);
  return path;
}

void _exportMain((SendPort, Map<String, dynamic>) message) {
  final (port, job) = message;
  final path = exportNow(job, onProgress: port.send);
  port.send(path);
}
