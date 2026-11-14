// Hand-written dart:ffi bindings for src/yt_audio.h.
// ignore_for_file: library_private_types_in_public_api
import 'dart:ffi';
import 'dart:io';

/// Opaque native engine handle.
final class YtEngine extends Opaque {}

typedef _VersionC = Int32 Function();
typedef _VersionD = int Function();
typedef _FreeC = Void Function(Pointer<Void>);
typedef _FreeD = void Function(Pointer<Void>);
typedef _DecodeC = Pointer<Float> Function(Pointer<Char>, Int32, Int32, Pointer<Int64>, Pointer<Char>, Int32);
typedef _DecodeD = Pointer<Float> Function(Pointer<Char>, int, int, Pointer<Int64>, Pointer<Char>, int);
typedef _EncodeC = Int32 Function(Pointer<Char>, Pointer<Float>, Int64, Int32, Int32, Int32);
typedef _EncodeD = int Function(Pointer<Char>, Pointer<Float>, int, int, int, int);
typedef _VoidC = Void Function();
typedef _VoidD = void Function();
typedef _Int2C = Int32 Function(Int32, Int32);
typedef _Int2D = int Function(int, int);
typedef _DoubleC = Double Function();
typedef _DoubleD = double Function();
typedef _Int64C = Int64 Function();
typedef _Int64D = int Function();

typedef _PathC = Int32 Function(Pointer<Char>);
typedef _PathD = int Function(Pointer<Char>);
typedef _StringC = Int32 Function(Pointer<Char>, Int32);
typedef _StringD = int Function(Pointer<Char>, int);

typedef _CreateC = Pointer<YtEngine> Function(Int32, Int32, Int32, Pointer<Char>, Int32);
typedef _CreateD = Pointer<YtEngine> Function(int, int, int, Pointer<Char>, int);
typedef _EngIntC = Int32 Function(Pointer<YtEngine>);
typedef _EngIntD = int Function(Pointer<YtEngine>);
typedef _EngVoidC = Void Function(Pointer<YtEngine>);
typedef _EngVoidD = void Function(Pointer<YtEngine>);
typedef _EngI64C = Int64 Function(Pointer<YtEngine>);
typedef _EngI64D = int Function(Pointer<YtEngine>);
typedef _LoadPcmC = Int32 Function(Pointer<YtEngine>, Int32, Pointer<Float>, Int64, Int32);
typedef _LoadPcmD = int Function(Pointer<YtEngine>, int, Pointer<Float>, int, int);
typedef _LoadFileC = Int32 Function(Pointer<YtEngine>, Int32, Pointer<Char>, Pointer<Char>, Int32);
typedef _LoadFileD = int Function(Pointer<YtEngine>, int, Pointer<Char>, Pointer<Char>, int);
typedef _EngSlotC = Void Function(Pointer<YtEngine>, Int32);
typedef _EngSlotD = void Function(Pointer<YtEngine>, int);
typedef _EngSlotGainC = Void Function(Pointer<YtEngine>, Int32, Float);
typedef _EngSlotGainD = void Function(Pointer<YtEngine>, int, double);
typedef _EngFloatC = Void Function(Pointer<YtEngine>, Float);
typedef _EngFloatD = void Function(Pointer<YtEngine>, double);
typedef _EngSetIntC = Void Function(Pointer<YtEngine>, Int32);
typedef _EngSetIntD = void Function(Pointer<YtEngine>, int);
typedef _EngSetI64C = Void Function(Pointer<YtEngine>, Int64);
typedef _EngSetI64D = void Function(Pointer<YtEngine>, int);
typedef _EngLoopC = Void Function(Pointer<YtEngine>, Int64, Int64);
typedef _EngLoopD = void Function(Pointer<YtEngine>, int, int);
typedef _ReadCapC = Int32 Function(
  Pointer<YtEngine>,
  Pointer<Float>,
  Int32,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Int32>,
);
typedef _ReadCapD = int Function(
  Pointer<YtEngine>,
  Pointer<Float>,
  int,
  Pointer<Int64>,
  Pointer<Int64>,
  Pointer<Int32>,
);
typedef _RenderC = Void Function(Pointer<YtEngine>, Pointer<Float>, Pointer<Float>, Int32);
typedef _RenderD = void Function(Pointer<YtEngine>, Pointer<Float>, Pointer<Float>, int);

/// Opens the native library for the current platform.
///
/// The environment variable `YINTRACE_AUDIO_LIB` overrides the location,
/// which is how host-side tests load a library built with CMake.
DynamicLibrary openYinTraceAudioLibrary() {
  final override = Platform.environment['YINTRACE_AUDIO_LIB'];
  if (override != null && override.isNotEmpty) {
    return DynamicLibrary.open(override);
  }
  if (Platform.isIOS || Platform.isMacOS) {
    // Statically linked pods (the iOS app links every pod statically for
    // ONNX Runtime) put the symbols into the process itself.
    final process = DynamicLibrary.process();
    if (process.providesSymbol('yt_api_version')) return process;
    return DynamicLibrary.open('yintrace_audio.framework/yintrace_audio');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('libyintrace_audio.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('yintrace_audio.dll');
  }
  throw UnsupportedError('Unsupported platform: ${Platform.operatingSystem}');
}

/// Raw bindings. Prefer the high level API in `native_audio.dart`.
class YtBindings {
  YtBindings(this.library)
    : apiVersion = library.lookupFunction<_VersionC, _VersionD>('yt_api_version'),
      free = library.lookupFunction<_FreeC, _FreeD>('yt_free'),
      freePointer = library.lookup<NativeFunction<_FreeC>>('yt_free'),
      decodeFile = library.lookupFunction<_DecodeC, _DecodeD>('yt_decode_file'),
      encodeM4a = library.lookupFunction<_EncodeC, _EncodeD>('yt_encode_m4a'),
      micPermissionStatus = library.lookupFunction<_VersionC, _VersionD>('yt_mic_permission_status'),
      requestMicPermission = library.lookupFunction<_VoidC, _VoidD>('yt_request_mic_permission'),
      configureSession = library.lookupFunction<_Int2C, _Int2D>('yt_configure_session'),
      sessionLatency = library.lookupFunction<_DoubleC, _DoubleD>('yt_session_latency'),
      availableMemory = library.lookupFunction<_Int64C, _Int64D>('yt_available_memory'),
      deviceModel = library.lookupFunction<_StringC, _StringD>('yt_device_model'),
      physicalMemory = library.lookupFunction<_Int64C, _Int64D>('yt_physical_memory'),
      thermalState = library.lookupFunction<_VersionC, _VersionD>('yt_thermal_state'),
      excludeFromBackup = library.lookupFunction<_PathC, _PathD>('yt_exclude_from_backup'),
      engineCreate = library.lookupFunction<_CreateC, _CreateD>('yt_engine_create'),
      engineStart = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_start'),
      engineStop = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_stop'),
      engineTakeAudioEvents = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_take_audio_events'),
      engineSignalAudioEvent = library.lookupFunction<_EngSetIntC, _EngSetIntD>(
        'yt_engine_signal_audio_event',
      ),
      engineDestroy = library.lookupFunction<_EngVoidC, _EngVoidD>('yt_engine_destroy'),
      engineSampleRate = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_sample_rate'),
      enginePeriodFrames = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_period_frames'),
      engineLoadTrackPcm = library.lookupFunction<_LoadPcmC, _LoadPcmD>('yt_engine_load_track_pcm'),
      engineLoadTrackFile = library.lookupFunction<_LoadFileC, _LoadFileD>('yt_engine_load_track_file'),
      engineUnloadTrack = library.lookupFunction<_EngSlotC, _EngSlotD>('yt_engine_unload_track'),
      engineSetTrackGain = library.lookupFunction<_EngSlotGainC, _EngSlotGainD>('yt_engine_set_track_gain'),
      engineSetMonitorGain = library.lookupFunction<_EngFloatC, _EngFloatD>('yt_engine_set_monitor_gain'),
      engineSetPlaying = library.lookupFunction<_EngSetIntC, _EngSetIntD>('yt_engine_set_playing'),
      engineIsPlaying = library.lookupFunction<_EngIntC, _EngIntD>('yt_engine_is_playing'),
      engineSeek = library.lookupFunction<_EngSetI64C, _EngSetI64D>('yt_engine_seek'),
      enginePosition = library.lookupFunction<_EngI64C, _EngI64D>('yt_engine_position'),
      engineLength = library.lookupFunction<_EngI64C, _EngI64D>('yt_engine_length'),
      engineSetLoop = library.lookupFunction<_EngLoopC, _EngLoopD>('yt_engine_set_loop'),
      engineEndCount = library.lookupFunction<_EngI64C, _EngI64D>('yt_engine_end_count'),
      engineReadCapture = library.lookupFunction<_ReadCapC, _ReadCapD>('yt_engine_read_capture'),
      engineCaptureOverruns = library.lookupFunction<_EngI64C, _EngI64D>('yt_engine_capture_overruns'),
      engineFlushCapture = library.lookupFunction<_EngVoidC, _EngVoidD>('yt_engine_flush_capture'),
      engineRender = library.lookupFunction<_RenderC, _RenderD>('yt_engine_render');

  final DynamicLibrary library;
  final int Function() apiVersion;
  final void Function(Pointer<Void>) free;
  final Pointer<NativeFunction<_FreeC>> freePointer;
  final _DecodeD decodeFile;
  final _EncodeD encodeM4a;
  final int Function() micPermissionStatus;
  final void Function() requestMicPermission;
  final int Function(int, int) configureSession;
  final double Function() sessionLatency;
  final int Function() availableMemory;
  final int Function(Pointer<Char>, int) deviceModel;
  final int Function() physicalMemory;
  final int Function() thermalState;
  final int Function(Pointer<Char>) excludeFromBackup;
  final _CreateD engineCreate;
  final _EngIntD engineStart;
  final _EngIntD engineStop;
  final _EngIntD engineTakeAudioEvents;
  final _EngSetIntD engineSignalAudioEvent;
  final _EngVoidD engineDestroy;
  final _EngIntD engineSampleRate;
  final _EngIntD enginePeriodFrames;
  final _LoadPcmD engineLoadTrackPcm;
  final _LoadFileD engineLoadTrackFile;
  final _EngSlotD engineUnloadTrack;
  final _EngSlotGainD engineSetTrackGain;
  final _EngFloatD engineSetMonitorGain;
  final _EngSetIntD engineSetPlaying;
  final _EngIntD engineIsPlaying;
  final _EngSetI64D engineSeek;
  final _EngI64D enginePosition;
  final _EngI64D engineLength;
  final _EngLoopD engineSetLoop;
  final _EngI64D engineEndCount;
  final _ReadCapD engineReadCapture;
  final _EngI64D engineCaptureOverruns;
  final _EngVoidD engineFlushCapture;
  final _RenderD engineRender;

  static YtBindings? _instance;

  /// Lazily opened, per-isolate bindings.
  static YtBindings get instance => _instance ??= YtBindings(openYinTraceAudioLibrary());
}
