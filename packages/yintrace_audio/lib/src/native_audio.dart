import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';

import 'bindings.dart';

/// Error raised by the native audio core.
class NativeAudioException implements Exception {
  NativeAudioException(this.message);
  final String message;
  @override
  String toString() => 'NativeAudioException: $message';
}

/// Decoded, interleaved float PCM.
class DecodedAudio {
  DecodedAudio(this.samples, this.channels, this.sampleRate)
      : assert(samples.length % channels == 0);

  /// Interleaved samples.
  final Float32List samples;
  final int channels;
  final int sampleRate;

  int get frames => samples.length ~/ channels;
  double get duration => frames / sampleRate;

  /// Returns one channel (or the average of both when [channel] is null).
  Float32List channel([int? channel]) {
    final out = Float32List(frames);
    if (channels == 1) {
      out.setAll(0, samples);
      return out;
    }
    if (channel == null) {
      for (var i = 0; i < frames; i++) {
        out[i] = 0.5 * (samples[2 * i] + samples[2 * i + 1]);
      }
    } else {
      for (var i = 0; i < frames; i++) {
        out[i] = samples[2 * i + channel];
      }
    }
    return out;
  }
}

enum MicPermission { undetermined, granted, denied }

/// Engine device modes.
enum EngineMode {
  playback(0),
  duplex(1),
  capture(2),
  offline(3);

  const EngineMode(this.value);
  final int value;
}

/// One block of captured microphone audio.
class CaptureBlock {
  CaptureBlock(this.samples, this.songFrame, this.clockFrame, this.playing);

  /// Mono samples at the engine sample rate.
  final Float32List samples;

  /// Song frame that was being rendered when the first sample was captured
  /// (not latency compensated).
  final int songFrame;

  /// Monotonic engine frame counter of the first sample.
  final int clockFrame;

  /// Whether the song was playing for this block.
  final bool playing;
}

/// Static helpers around the native core.
class NativeAudio {
  NativeAudio._();

  static YtBindings get _b => YtBindings.instance;

  /// Whether the native library can be loaded on this platform.
  static bool get isAvailable {
    try {
      return _b.apiVersion() >= 1;
    } catch (_) {
      return false;
    }
  }

  /// Decodes an audio file (mp3, m4a/aac, wav, flac, ... depending on the
  /// platform) to float PCM. This is CPU heavy; call it from an isolate.
  static DecodedAudio decodeFile(String path,
      {int sampleRate = 44100, int channels = 2}) {
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena).cast<Char>();
      final frames = arena<Int64>();
      final err = arena<Char>(512);
      final ptr = _b.decodeFile(cPath, sampleRate, channels, frames, err, 512);
      if (ptr == nullptr) {
        throw NativeAudioException(
            'decode failed: ${err.cast<Utf8>().toDartString()}');
      }
      final count = frames.value * channels;
      final view = ptr.asTypedList(count);
      final copy = Float32List.fromList(view);
      _b.free(ptr.cast());
      return DecodedAudio(copy, channels, sampleRate);
    });
  }

  /// Encodes PCM to AAC/.m4a. Returns false when the platform has no
  /// encoder (callers should fall back to WAV).
  static bool encodeM4a(String path, Float32List interleaved, int sampleRate,
      int channels,
      {int bitrate = 160000}) {
    return using((arena) {
      final cPath = path.toNativeUtf8(allocator: arena).cast<Char>();
      final data = arena<Float>(interleaved.length);
      data.asTypedList(interleaved.length).setAll(0, interleaved);
      final r = _b.encodeM4a(cPath, data, interleaved.length ~/ channels,
          sampleRate, channels, bitrate);
      if (r == -1) return false;
      if (r != 0) throw NativeAudioException('AAC encoding failed ($r)');
      return true;
    });
  }

  static MicPermission get micPermission =>
      MicPermission.values[_b.micPermissionStatus().clamp(0, 2)];

  /// Shows the system microphone prompt if needed and waits for the answer.
  static Future<MicPermission> requestMicPermission(
      {Duration timeout = const Duration(minutes: 2)}) async {
    var status = micPermission;
    if (status != MicPermission.undetermined) return status;
    _b.requestMicPermission();
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      await Future<void>.delayed(const Duration(milliseconds: 150));
      status = micPermission;
      if (status != MicPermission.undetermined) return status;
    }
    return status;
  }

  /// Configures the shared audio session (iOS). Returns 0 on success.
  static int configureSession({required bool record, bool measurement = false}) =>
      _b.configureSession(record ? 1 : 0, measurement ? 1 : 0);

  /// Input + output hardware latency reported by the OS, in seconds.
  static double get sessionLatency => _b.sessionLatency();

  /// Excludes a file or directory from device backups (for data that can be
  /// downloaded again). Returns whether the platform accepted it.
  static bool excludeFromBackup(String path) {
    final p = path.toNativeUtf8();
    try {
      return _b.excludeFromBackup(p.cast()) == 0;
    } finally {
      malloc.free(p);
    }
  }
}

/// A full-duplex practice engine: plays up to four tracks in sync and
/// captures the microphone with song-position tags.
class PracticeEngine {
  PracticeEngine._(this._ptr, this.sampleRate, this.mode)
      : _capBuf = malloc<Float>(_capMax),
        _song = malloc<Int64>(),
        _clock = malloc<Int64>(),
        _flags = malloc<Int32>();

  static const int maxTracks = 4;
  static const int _capMax = 4096;

  final Pointer<YtEngine> _ptr;
  final int sampleRate;
  final EngineMode mode;
  final Pointer<Float> _capBuf;
  final Pointer<Int64> _song;
  final Pointer<Int64> _clock;
  final Pointer<Int32> _flags;
  bool _disposed = false;

  static YtBindings get _b => YtBindings.instance;

  static PracticeEngine create(
      {int sampleRate = 44100,
      EngineMode mode = EngineMode.duplex,
      bool nullBackend = false}) {
    return using((arena) {
      final err = arena<Char>(512);
      final ptr =
          _b.engineCreate(sampleRate, mode.value, nullBackend ? 1 : 0, err, 512);
      if (ptr == nullptr) {
        throw NativeAudioException(
            'engine init failed: ${err.cast<Utf8>().toDartString()}');
      }
      return PracticeEngine._(ptr, sampleRate, mode);
    });
  }

  void _check() {
    if (_disposed) throw StateError('PracticeEngine disposed');
  }

  void start() {
    _check();
    final r = _b.engineStart(_ptr);
    if (r != 0) throw NativeAudioException('cannot start audio device ($r)');
  }

  void stop() {
    _check();
    _b.engineStop(_ptr);
  }

  void dispose() {
    if (_disposed) return;
    _disposed = true;
    _b.engineDestroy(_ptr);
    malloc.free(_capBuf);
    malloc.free(_song);
    malloc.free(_clock);
    malloc.free(_flags);
  }

  /// Device period in engine frames (0 when unknown/offline).
  int get periodFrames => _b.enginePeriodFrames(_ptr);

  void loadTrackPcm(int slot, Float32List interleaved, int channels) {
    _check();
    using((arena) {
      final data = arena<Float>(interleaved.length);
      data.asTypedList(interleaved.length).setAll(0, interleaved);
      final r = _b.engineLoadTrackPcm(
          _ptr, slot, data, interleaved.length ~/ channels, channels);
      if (r != 0) throw NativeAudioException('load track failed ($r)');
    });
  }

  void loadTrackFile(int slot, String path) {
    _check();
    using((arena) {
      final err = arena<Char>(512);
      final r = _b.engineLoadTrackFile(_ptr, slot,
          path.toNativeUtf8(allocator: arena).cast<Char>(), err, 512);
      if (r != 0) {
        throw NativeAudioException(
            'load track failed: ${err.cast<Utf8>().toDartString()}');
      }
    });
  }

  void unloadTrack(int slot) {
    _check();
    _b.engineUnloadTrack(_ptr, slot);
  }

  void setTrackGain(int slot, double gain) {
    _check();
    _b.engineSetTrackGain(_ptr, slot, gain);
  }

  void setMonitorGain(double gain) {
    _check();
    _b.engineSetMonitorGain(_ptr, gain);
  }

  void play() {
    _check();
    _b.engineSetPlaying(_ptr, 1);
  }

  void pause() {
    _check();
    _b.engineSetPlaying(_ptr, 0);
  }

  bool get isPlaying => !_disposed && _b.engineIsPlaying(_ptr) != 0;

  void seekFrame(int frame) {
    _check();
    _b.engineSeek(_ptr, frame);
  }

  void seek(Duration position) =>
      seekFrame((position.inMicroseconds * sampleRate / 1e6).round());

  int get positionFrame => _disposed ? 0 : _b.enginePosition(_ptr);
  double get positionSeconds => positionFrame / sampleRate;
  int get lengthFrames => _disposed ? 0 : _b.engineLength(_ptr);
  double get lengthSeconds => lengthFrames / sampleRate;

  /// Loops playback inside [start, end) seconds; null disables looping.
  void setLoop(double? startSeconds, double? endSeconds) {
    _check();
    if (startSeconds == null || endSeconds == null) {
      _b.engineSetLoop(_ptr, 0, 0);
    } else {
      _b.engineSetLoop(_ptr, (startSeconds * sampleRate).round(),
          (endSeconds * sampleRate).round());
    }
  }

  /// Increments every time playback reaches the end.
  int get endCount => _b.engineEndCount(_ptr);

  int get captureOverruns => _b.engineCaptureOverruns(_ptr);

  void flushCapture() {
    _check();
    _b.engineFlushCapture(_ptr);
  }

  /// Drains all pending captured blocks.
  List<CaptureBlock> readCapture({int maxBlocks = 512}) {
    if (_disposed) return const [];
    final out = <CaptureBlock>[];
    for (var i = 0; i < maxBlocks; i++) {
      final n = _b.engineReadCapture(_ptr, _capBuf, _capMax, _song, _clock, _flags);
      if (n <= 0) break;
      out.add(CaptureBlock(Float32List.fromList(_capBuf.asTypedList(n)),
          _song.value, _clock.value, (_flags.value & 1) != 0));
    }
    return out;
  }

  /// Runs the audio callback directly (offline mode / tests).
  /// Returns the rendered interleaved stereo output.
  Float32List render(int frames, {Float32List? input}) {
    _check();
    return using((arena) {
      final out = arena<Float>(frames * 2);
      Pointer<Float> inp = nullptr;
      if (input != null) {
        inp = arena<Float>(frames);
        inp.asTypedList(frames).setAll(0, input.sublist(0, frames));
      }
      _b.engineRender(_ptr, out, inp, frames);
      return Float32List.fromList(out.asTypedList(frames * 2));
    });
  }
}
