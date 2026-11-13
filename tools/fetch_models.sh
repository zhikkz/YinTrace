#!/usr/bin/env bash
# Downloads the two UVR models YinTrace uses into a folder (default
# build/uvr-models) and checks their SHA-256. For tests and tools only: the
# app downloads the models itself.
set -euo pipefail
OUT="${1:-build/uvr-models}"
BASE="https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models"
mkdir -p "$OUT"
fetch() {
  local name="$1" sum="$2"
  if [ ! -f "$OUT/$name" ] || ! echo "$sum  $OUT/$name" | shasum -a 256 -c - >/dev/null 2>&1; then
    echo "downloading $name"
    curl -fL --retry 3 -o "$OUT/$name" "$BASE/$name"
  fi
  echo "$sum  $OUT/$name" | shasum -a 256 -c -
}
fetch UVR-MDX-NET-Voc_FT.onnx 534b2070fcc7df514b13ef660dc8cbb328679c2374d04354a5c42bb14ecce111
fetch 6_HP-Karaoke-UVR.pth 4ce7eaaa9e56f09366b788aebf6d3a72aec8145692c56f1e090e4e7e2d7ce65f
