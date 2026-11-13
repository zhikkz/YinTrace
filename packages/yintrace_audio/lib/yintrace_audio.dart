/// YinTrace native audio core: decoding, AAC encoding and a full-duplex
/// practice engine, accessed through dart:ffi.
library;

export 'src/bindings.dart' show YtBindings, openYinTraceAudioLibrary;
export 'src/native_audio.dart';
