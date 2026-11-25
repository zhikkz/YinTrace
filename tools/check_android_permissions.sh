#!/usr/bin/env bash
# Fails unless each release APK asks for the permissions the app needs. The
# debug manifest adds INTERNET by itself, so only a release build shows that
# it is missing: model downloads and the update check need it.
#   tools/check_android_permissions.sh <apk>...
set -euo pipefail
apkanalyzer="$ANDROID_HOME/cmdline-tools/latest/bin/apkanalyzer"
for apk in "$@"; do
  permissions=$("$apkanalyzer" manifest permissions "$apk")
  echo "$apk:"
  echo "$permissions" | sed 's/^/  /'
  for needed in android.permission.INTERNET android.permission.RECORD_AUDIO; do
    if ! grep -qx "$needed" <<<"$permissions"; then
      echo "::error::$apk does not ask for $needed."
      exit 1
    fi
  done
done
