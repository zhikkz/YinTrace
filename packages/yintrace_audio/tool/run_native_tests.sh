#!/usr/bin/env bash
# Builds the native core and runs the C tests on the host (Linux/macOS).
# Requires cmake, a C compiler and ffmpeg (to create test audio files).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build/native-test}"
mkdir -p "$BUILD"
if [ "$(uname)" = "Darwin" ]; then
  # Compile the core as Objective-C like the iOS/macOS pods do, so the
  # Core Audio (ExtAudioFile) decode/encode path is exercised.
  cc -O2 -Wall -Wextra -Wno-unused-parameter -o "$BUILD/engine_test" \
    "$ROOT/test/native/engine_test.c" -x objective-c -fobjc-arc "$ROOT/src/yt_audio.c" -x none \
    -framework Foundation -framework AVFoundation -framework AudioToolbox -framework CoreAudio
else
  cc -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -o "$BUILD/engine_test" \
    "$ROOT/test/native/engine_test.c" "$ROOT/src/yt_audio.c" -lm -lpthread -ldl
fi
ARGS=()
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=48000" -ac 1 "$BUILD/tone48k_mono.wav"
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -ac 2 -b:a 192k "$BUILD/tone.mp3"
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -ac 2 "$BUILD/tone.flac"
  ARGS=("$BUILD/tone48k_mono.wav" 132300 "$BUILD/tone.mp3" 132300 "$BUILD/tone.flac" 132300)
elif command -v afconvert >/dev/null 2>&1 && command -v python3 >/dev/null 2>&1; then
  # macOS without ffmpeg: write a WAV with Python and let Core Audio make the
  # FLAC and Apple Lossless versions.
  python3 - "$BUILD/tone48k_mono.wav" <<'PY'
import math, struct, sys, wave
w = wave.open(sys.argv[1], "wb")
w.setnchannels(1); w.setsampwidth(2); w.setframerate(48000)
w.writeframes(b"".join(struct.pack("<h", int(12000 * math.sin(2 * math.pi * 440 * i / 48000))) for i in range(48000 * 3)))
w.close()
PY
  afconvert -f flac -d flac "$BUILD/tone48k_mono.wav" "$BUILD/tone.flac"
  afconvert -f m4af -d alac "$BUILD/tone48k_mono.wav" "$BUILD/tone_alac.m4a"
  ARGS=("$BUILD/tone48k_mono.wav" 132300 "$BUILD/tone.flac" 132300 "$BUILD/tone_alac.m4a" 132300)
fi
# ("${ARGS[@]}" alone is an error under `set -u` in the bash 3.2 of macOS.)
"$BUILD/engine_test" ${ARGS[@]+"${ARGS[@]}"}
