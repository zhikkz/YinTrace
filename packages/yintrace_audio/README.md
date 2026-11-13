# yintrace_audio

YinTrace's native audio core, used through `dart:ffi`.

- **Decoding** (`NativeAudio.decodeFile`): Core Audio `ExtAudioFile` on iOS/macOS
  (mp3, aac/m4a, alac, wav, aiff, caf, flac), miniaudio elsewhere (wav, mp3, flac).
- **AAC encoding** (`NativeAudio.encodeM4a`): Apple platforms; returns `false` elsewhere.
- **Audio session / microphone permission** on iOS and macOS.
- **`PracticeEngine`**: a full-duplex engine on miniaudio that plays up to four
  in-memory tracks (stored as int16) with per-track gains, seeking and A–B looping,
  and captures the microphone. Every captured block is tagged with the song frame
  that was being rendered in the same audio callback, so the app can map each
  sung sample to a song position exactly (loop jumps split blocks).
  Nothing calls back into Dart: captured audio is polled with `readCapture()`.

The C sources live in `src/` and are shared by all platforms:
CocoaPods compiles them as Objective-C through the forwarders in
`ios/Classes` and `macos/Classes`; Android and Windows use `src/CMakeLists.txt`.

Tests:

```bash
tool/run_native_tests.sh   # C tests (engine + decoders); on macOS also the Core Audio path
tool/run_dart_tests.sh     # builds the library for the host and runs the Dart tests
```
