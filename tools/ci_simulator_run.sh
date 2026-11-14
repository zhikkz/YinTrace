#!/usr/bin/env bash
# CI only: runs a command against the iPhone simulator ($YINTRACE_SIMULATOR).
# The hosted macOS runners sometimes never launch the test app (simctl hangs
# right after "Xcode build done"). When the command gives no result within
# <seconds>, restart the simulator and try once more. A test that fails on
# its own is not retried.
#
#   tools/ci_simulator_run.sh <seconds> <command> [args...]
set -uo pipefail
limit="$1"
shift
set -m # background jobs get their own process group, so the whole tree can be stopped
for attempt in 1 2; do
  marker="$(mktemp -u)"
  "$@" &
  pid=$!
  (
    sleep "$limit"
    if kill -0 "$pid" 2>/dev/null; then
      touch "$marker"
      kill -TERM -- "-$pid" 2>/dev/null
    fi
  ) &
  watchdog=$!
  wait "$pid"
  status=$?
  kill "$watchdog" 2>/dev/null
  wait "$watchdog" 2>/dev/null
  if [ ! -e "$marker" ]; then
    exit "$status"
  fi
  rm -f "$marker"
  echo "::warning::no result after ${limit} s (attempt $attempt); restarting the simulator"
  pkill -TERM -f "simctl" || true
  xcrun simctl shutdown "$YINTRACE_SIMULATOR" || true
  xcrun simctl boot "$YINTRACE_SIMULATOR"
  xcrun simctl bootstatus "$YINTRACE_SIMULATOR" -b
done
echo "::error::the simulator did not run the test app in two attempts"
exit 1
