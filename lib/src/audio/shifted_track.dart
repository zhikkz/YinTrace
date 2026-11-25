import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../dsp/key_shift.dart';
import '../models/model_recipe.dart' show sha256OfFileSync;
import 'wav.dart';

/// A practice stem on the original song timeline. Decode on a worker isolate.
class ShiftedTrack {
  const ShiftedTrack(this.path, this.transpose, {this.cacheDirectory, this.sampleRate = 44100});

  final String path;
  final int transpose;
  final String? cacheDirectory;
  final int sampleRate;
  static const _version = 1;
  static const _channels = 2;

  DecodedAudio decode({void Function(double)? onProgress}) {
    if (transpose == 0) return NativeAudio.decodeFile(path, sampleRate: sampleRate);
    final directory = cacheDirectory;
    final source = File(path);
    final stamp = source.statSync();
    final File? cached;
    if (directory != null) {
      final identity = sha256.convert(
        utf8.encode('${source.uri.pathSegments.last}\n${sha256OfFileSync(path)}'),
      );
      cached = File('$directory/v$_version-$sampleRate-$transpose-$identity.wav');
      final frames = _cachedFrames(cached);
      if (frames != null) {
        try {
          final audio = NativeAudio.decodeFile(cached.path, sampleRate: sampleRate);
          if (audio.frames == frames) {
            onProgress?.call(1);
            return audio;
          }
        } on NativeAudioException {
          // A cache file can disappear or become unreadable. Regenerate it.
        }
      }
    } else {
      cached = null;
    }

    final original = NativeAudio.decodeFile(path, sampleRate: sampleRate);
    onProgress?.call(0.05);
    final samples = shiftKey(
      original.samples,
      channels: original.channels,
      sampleRate: sampleRate,
      semitones: transpose,
      onProgress: (p) => onProgress?.call(0.05 + p * 0.9),
    );
    final now = source.statSync();
    if (stamp.size != now.size || stamp.modified != now.modified || stamp.changed != now.changed) {
      throw StateError('变调期间音频文件发生了变化');
    }
    if (cached != null) _writeCache(cached, samples);
    onProgress?.call(1);
    return DecodedAudio(samples, original.channels, sampleRate);
  }

  int? _cachedFrames(File file) {
    try {
      final input = file.openSync();
      try {
        final header = input.readSync(44);
        final bytes = input.lengthSync() - 44;
        if (header.length != 44 || bytes <= 0 || bytes % (2 * _channels) != 0) return null;
        final expected = wav16Header(bytes ~/ 2, _channels, sampleRate);
        for (var i = 0; i < header.length; i++) {
          if (header[i] != expected[i]) return null;
        }
        return bytes ~/ (2 * _channels);
      } finally {
        input.closeSync();
      }
    } on FileSystemException {
      return null;
    }
  }

  void _writeCache(File target, Float32List samples) {
    Directory? temp;
    try {
      // A unique staging directory lets two readers fill the same entry.
      // Never recreate the song's cache directory if it was deleted.
      temp = target.parent.createTempSync('write-');
      final file = File('${temp.path}/audio.wav');
      final out = file.openSync(mode: FileMode.write);
      try {
        out.writeFromSync(wav16Header(samples.length, _channels, sampleRate));
        final pcm = Int16List(1 << 18);
        final bytes = pcm.buffer.asUint8List();
        for (var at = 0; at < samples.length; at += pcm.length) {
          final n = math.min(pcm.length, samples.length - at);
          for (var i = 0; i < n; i++) {
            pcm[i] = (samples[at + i] * 32767).round();
          }
          out.writeFromSync(bytes, 0, n * 2);
        }
      } finally {
        out.closeSync();
      }
      file.renameSync(target.path);
    } on FileSystemException {
      // The result can still be played when there is no room in the cache.
    } finally {
      try {
        temp?.deleteSync(recursive: true);
      } on FileSystemException {
        // It may have been removed with the song.
      }
    }
  }
}
