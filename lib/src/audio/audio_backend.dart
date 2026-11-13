import 'dart:io';
import 'dart:typed_data';

import 'package:yintrace_audio/yintrace_audio.dart';

import 'wav.dart';

/// File decoding / encoding used by the import pipeline. The default
/// implementation uses the native audio core; tests use [WavAudioBackend].
abstract class AudioBackend {
  /// Decodes any supported audio file to interleaved float PCM.
  DecodedAudio decode(String path, {int sampleRate = 44100, int channels = 2});

  /// Writes a compressed copy (AAC .m4a) when the platform can, else WAV.
  /// Returns the path actually written (the extension may change).
  String writeCompressed(String pathWithoutExtension, Float32List interleaved,
      int channels, int sampleRate,
      {int bitrate = 160000});
}

class NativeAudioBackend implements AudioBackend {
  const NativeAudioBackend();

  @override
  DecodedAudio decode(String path, {int sampleRate = 44100, int channels = 2}) {
    // WAV is decoded in Dart so that it also works where the native
    // decoder lacks a format (and to keep exact float samples).
    if (path.toLowerCase().endsWith('.wav')) {
      try {
        return const WavAudioBackend().decode(path, sampleRate: sampleRate, channels: channels);
      } on FormatException {
        // fall through to the native decoder (e.g. unusual WAV encodings)
      }
    }
    return NativeAudio.decodeFile(path, sampleRate: sampleRate, channels: channels);
  }

  @override
  String writeCompressed(String base, Float32List interleaved, int channels, int sampleRate,
      {int bitrate = 160000}) {
    final m4a = '$base.m4a';
    try {
      if (NativeAudio.encodeM4a(m4a, interleaved, sampleRate, channels, bitrate: bitrate)) {
        return m4a;
      }
    } on NativeAudioException {
      final f = File(m4a);
      if (f.existsSync()) f.deleteSync();
    }
    final wav = '$base.wav';
    writeWavFile(wav, interleaved, channels, sampleRate);
    return wav;
  }
}

/// Pure Dart backend: WAV only (used in tests and as a fallback).
class WavAudioBackend implements AudioBackend {
  const WavAudioBackend();

  @override
  DecodedAudio decode(String path, {int sampleRate = 44100, int channels = 2}) {
    final w = readWavFile(path);
    var data = w.samples;
    var ch = w.channels;
    if (ch > 2) {
      final frames = w.frames;
      final d = Float32List(frames * 2);
      for (var i = 0; i < frames; i++) {
        d[2 * i] = data[i * ch];
        d[2 * i + 1] = data[i * ch + 1];
      }
      data = d;
      ch = 2;
    }
    if (ch != channels) {
      final frames = data.length ~/ ch;
      final d = Float32List(frames * channels);
      for (var i = 0; i < frames; i++) {
        if (channels == 1) {
          d[i] = 0.5 * (data[2 * i] + data[2 * i + 1]);
        } else {
          d[2 * i] = data[i];
          d[2 * i + 1] = data[i];
        }
      }
      data = d;
    }
    if (w.sampleRate != sampleRate) {
      data = _resampleInterleaved(data, channels, w.sampleRate, sampleRate);
    }
    return DecodedAudio(data, channels, sampleRate);
  }

  static Float32List _resampleInterleaved(Float32List x, int ch, int from, int to) {
    final frames = x.length ~/ ch;
    final outFrames = (frames * to / from).floor();
    final out = Float32List(outFrames * ch);
    // Linear interpolation is enough for the test/fallback path.
    for (var i = 0; i < outFrames; i++) {
      final pos = i * from / to;
      final j = pos.floor();
      final f = pos - j;
      for (var c = 0; c < ch; c++) {
        final a = x[(j.clamp(0, frames - 1)) * ch + c];
        final b = x[((j + 1).clamp(0, frames - 1)) * ch + c];
        out[i * ch + c] = a + (b - a) * f;
      }
    }
    return out;
  }

  @override
  String writeCompressed(String base, Float32List interleaved, int channels, int sampleRate,
      {int bitrate = 160000}) {
    final wav = '$base.wav';
    writeWavFile(wav, interleaved, channels, sampleRate);
    return wav;
  }
}
