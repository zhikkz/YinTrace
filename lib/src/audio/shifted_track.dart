import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:yintrace_audio/yintrace_audio.dart';

import '../dsp/key_shift.dart';
import '../models/model_recipe.dart' show sha256OfFileSync;
import 'key_shift_cache.dart';
import 'wav.dart';

/// A practice stem on the original song timeline. Decode on a worker isolate.
class ShiftedTrack {
  const ShiftedTrack(this.path, this.transpose, {this.cache, this.sampleRate = 44100});

  final String path;
  final int transpose;
  final KeyShiftCache? cache;
  final int sampleRate;
  static const _channels = 2;

  DecodedAudio decode({void Function(double)? onProgress}) {
    if (transpose == 0) {
      return NativeAudio.decodeFile(path, sampleRate: sampleRate);
    }
    final source = File(path);
    final stamp = source.statSync();
    bool isCurrent() {
      final now = source.statSync();
      return stamp.size == now.size && stamp.modified == now.modified && stamp.changed == now.changed;
    }

    final entry = cache?.entry(source.uri.pathSegments.last, sha256OfFileSync(path), sampleRate, transpose);
    final hit = entry?.read(_readCache, isCurrent: isCurrent);
    if (hit != null) {
      onProgress?.call(1);
      return hit;
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
    if (!isCurrent()) throw StateError('变调期间音频文件发生了变化');
    entry?.store(44 + samples.length * 2, (file) => _writeWav(file, samples), isCurrent: isCurrent);
    onProgress?.call(1);
    return DecodedAudio(samples, original.channels, sampleRate);
  }

  DecodedAudio? _readCache(File file) {
    final frames = _cachedFrames(file);
    if (frames == null) return null;
    try {
      final audio = NativeAudio.decodeFile(file.path, sampleRate: sampleRate);
      return audio.frames == frames ? audio : null;
    } on NativeAudioException {
      // The system can purge the cache. Regenerate it if it cannot be read.
      return null;
    }
  }

  int? _cachedFrames(File file) {
    try {
      final input = file.openSync();
      try {
        final header = input.readSync(44);
        final bytes = input.lengthSync() - 44;
        if (header.length != 44 || bytes <= 0 || bytes % (2 * _channels) != 0) {
          return null;
        }
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

  void _writeWav(File file, Float32List samples) {
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
  }
}
