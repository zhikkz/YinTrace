#!/usr/bin/env bash
# Builds the native core and runs the C tests on the host (Linux/macOS).
# Requires cmake, a C compiler and ffmpeg (to create test audio files).
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build/native-test}"
mkdir -p "$BUILD"
cc -std=c11 -O2 -Wall -Wextra -Wno-unused-parameter -o "$BUILD/engine_test" \
  "$ROOT/test/native/engine_test.c" "$ROOT/src/yt_audio.c" -lm -lpthread -ldl
ARGS=()
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=48000" -ac 1 "$BUILD/tone48k_mono.wav"
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -ac 2 -b:a 192k "$BUILD/tone.mp3"
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=44100" -ac 2 "$BUILD/tone.flac"
  ARGS=("$BUILD/tone48k_mono.wav" 132300 "$BUILD/tone.mp3" 132300 "$BUILD/tone.flac" 132300)
fi
"$BUILD/engine_test" "${ARGS[@]}"
