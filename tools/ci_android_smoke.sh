#!/usr/bin/env bash
# Runs the Android smoke test on the booted emulator, with
# tools/ci_android_allow_microphone.py answering the microphone prompt the
# test raises. CI only (the android job in .github/workflows/ci.yml).
set -uo pipefail
mkdir -p build
python3 tools/ci_android_allow_microphone.py > build/allow-microphone.log 2>&1 &
helper=$!
flutter test integration_test/android_smoke_test.dart -d emulator-5554 --reporter expanded
status=$?
kill "$helper" 2>/dev/null || true
wait "$helper" 2>/dev/null || true
echo "--- microphone prompt helper"
cat build/allow-microphone.log
exit "$status"
