#!/usr/bin/env bash
# Builds the native core for the host with CMake and runs the Dart tests.
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
BUILD="${BUILD_DIR:-$ROOT/build/host}"
cmake -S "$ROOT/src" -B "$BUILD" -DCMAKE_BUILD_TYPE=Release >/dev/null
cmake --build "$BUILD" >/dev/null
LIB="$(ls "$BUILD"/libyintrace_audio.* | head -n1)"
if command -v ffmpeg >/dev/null 2>&1; then
  ffmpeg -loglevel error -y -f lavfi -i "sine=frequency=440:duration=3:sample_rate=48000" "$BUILD/tone.wav"
  export YINTRACE_TEST_WAV="$BUILD/tone.wav"
fi
cd "$ROOT"
YINTRACE_AUDIO_LIB="$LIB" flutter test "$@"
