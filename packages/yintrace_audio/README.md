# yintrace_audio

YinTrace's native audio core, used through `dart:ffi`.

- **Decoding** (`NativeAudio.decodeFile`): Core Audio `ExtAudioFile` on iOS/macOS
  (mp3, aac/m4a, alac, wav, aiff, caf, flac); on Android miniaudio (wav, mp3, flac) and
  the NDK's `AMediaExtractor`/`AMediaCodec` (aac/m4a, ogg and the other formats the
  device decodes); miniaudio elsewhere (wav, mp3, flac).
- **AAC encoding** (`NativeAudio.encodeM4a`): Apple platforms; returns `false` elsewhere.
- **Audio session / microphone permission** on iOS and macOS; the microphone
  permission on Android (`YintraceAudioPlugin`, a method channel).
- **`PracticeEngine`**: a full-duplex engine on miniaudio that plays up to four
  in-memory tracks (stored as int16) with per-track gains, seeking and A–B looping,
  and captures the microphone. Every captured block is tagged with the song frame
  that was being rendered in the same audio callback, so the app can map each
  sung sample to a song position exactly (loop jumps split blocks).
  Nothing calls back into Dart: captured audio is polled with `readCapture()`.
- **Wired microphone monitoring**: `monitorAvailable` checks an iOS wired
  headphone/USB route; `setMonitorGain(0..1)` mixes the dry mic to both output
  channels in the native callback while playing. Pauses/end-of-track mute it;
  route changes and device stops clear the gain. Callers re-check availability
  before reapplying. Unknown routes/platforms and null devices reject it;
  offline engines allow it for deterministic tests. Capture stays dry.

The C sources live in `src/` and are shared by all platforms:
CocoaPods compiles them as Objective-C through the forwarders in
`ios/Classes` and `macos/Classes`; Android and Windows use `src/CMakeLists.txt`.

Tests:

```bash
tool/run_native_tests.sh   # C tests (engine + decoders); on macOS also the Core Audio path
tool/run_dart_tests.sh     # builds the library for the host and runs the Dart tests
```
