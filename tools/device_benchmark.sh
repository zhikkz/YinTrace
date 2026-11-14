#!/usr/bin/env bash
# 在连着的 iPhone 上测人声分离的速度和内存（profile 构建，速度接近正式版）：
#   1. 两个模型分别用 CPU（不同线程数）和几种 Core ML 设置运行，比较加载时间、
#      每次推理时间、内存峰值，以及 Core ML 的结果和 CPU 差多少；
#   2. 用 App 实际的导入流程完整导入一首合成歌曲，记录各阶段耗时和“预计还需”的误差。
#
#   tools/device_benchmark.sh                      列出设备
#   tools/device_benchmark.sh <设备 ID> [歌曲秒数]  测速，歌曲默认 60 秒（想看整首歌可以用 240）
#
# 需要：Mac、Xcode、Flutter 3.47.9，iPhone 已连接并信任这台 Mac，
# ios/Runner 已在 Xcode 里选好开发者团队（和平时 flutter run 一样）。
# 第一次运行会在手机上下载两个 UVR 模型（194 MB）。全程 10 分钟左右，请保持手机亮屏解锁。
# 结果：终端里的表格，build/device-benchmark.md（可以直接发给开发者）和
# build/integration_response_data.json（原始数据）。测试只用合成音频，不上传任何东西。
set -euo pipefail
cd "$(dirname "$0")/.."
export BOT=true FLUTTER_SUPPRESS_ANALYTICS=true ORT_DISABLE_TELEMETRY=1

if [ $# -lt 1 ]; then
  flutter devices
  echo
  echo "用法：$0 <设备 ID> [合成歌曲秒数，默认 60]"
  exit 1
fi
DEVICE="$1"
SONG_SECONDS="${2:-60}"
case "$SONG_SECONDS" in
  ''|*[!0-9]*) echo "歌曲秒数要是整数：$SONG_SECONDS"; exit 1 ;;
esac

MODE=--profile
if xcrun simctl list devices 2>/dev/null | grep -q -- "$DEVICE"; then
  # 模拟器没有 profile 模式，也没有神经网络引擎：只能说明能跑，数字不代表 iPhone。
  MODE=--debug
  echo "注意：$DEVICE 是模拟器，结果只能说明能跑，不代表 iPhone 的速度。"
fi

rm -f build/integration_response_data.json
flutter drive "$MODE" -d "$DEVICE" \
  --driver=test_driver/integration_test.dart \
  --target=integration_test/device_benchmark_test.dart \
  --dart-define=BENCH_SONG_SECONDS="$SONG_SECONDS"

python3 tools/benchmark_report.py build/integration_response_data.json build/device-benchmark.md
