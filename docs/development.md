# 开发：项目结构、测试与移植

## 项目结构

```
lib/
  main.dart
  src/
    dsp/          实数 FFT、STFT/iSTFT、多相重采样、SwiftF0 音高模型的输入输出、YIN、音高换算
    separation/   MDX-Net 与 VR 推理流程（UVR 移植）、模型配置、ONNX Runtime 封装
    analysis/     LRC 解析、语言识别（中/英/日）、离线音高跟踪、逐字对齐、参考旋律与校正
    import/       导入流水线（后台 isolate）
    library/      本地曲库（每首歌一个目录）、练习记录、我的录音、发给别人的歌曲文件
    practice/     实时音高跟踪（YIN）、评分、练习会话、校正页的片段播放
    export/       制作成品：混音、后台导出、保存录音
    models/       两个分离模型的下载、校验、动态时间轴配方与 .pth → ONNX 组装；随 App 附带的音高模型
    app/          设置、全局服务、第三方许可登记
    ui/           曲库 / 导入 / 歌曲 / 校正位置和音高 / 练习 / 评分 / 制作成品 / 自由练习 / 设置 页面，音高图绘制
packages/flutter_onnxruntime/ 固定 1.9.0 的本地副本，补齐 Apple useArena（保留 MIT 许可）
packages/yintrace_audio/   原生音频核心（C + miniaudio，dart:ffi）
  src/yt_audio.c            解码、全双工练习引擎、采集环形缓冲（带歌曲帧号）
  src/yt_platform_apple.inc AVAudioSession（线路变化按原因区分）、麦克风权限、ExtAudioFile 解码、
                            AAC 编码、系统分享面板
  src/yt_device_ios.inc     iPhone 上练习用的低延迟全双工设备（一个 RemoteIO 单元，同一周期取麦克风）
  src/yt_rate_bridge.h      在硬件采样率（多为 48 kHz）的回调里运行 44.1 kHz 的引擎（纯 C，有原生测试）
tools/
  build_pitch_model.py      从 swift-f0 官方 wheel 生成随 App 附带的 assets/models/swift_f0.onnx，并核对和原模型一致
  build_karaoke_graph.py    生成 assets/models 里的网络结构和拷贝配方，并与 PyTorch 对照验证
  fetch_models.sh           给测试和工具用：下载两个模型并校验
  reference/                生成测试参考数据的脚本（numpy / torch / librosa / UVR 原代码）
test/                       单元测试、对照测试、端到端 UI 测试
```

本地数据：

- 曲库在 App 的 Application Support 目录 `songs/<id>/`：`song.json`（信息与歌词）、
  `reference.json`（逐字音高图）、`pitch.bin`（音高曲线；现在的版本还存着频谱包络的变化，
  以前导入的歌没有，“修改歌词 / 重新对齐”时就只用音高和音量，重新导入才会有）、`vocals.m4a`（主唱）、
  `accompaniment.m4a`（伴奏）、`history.json`（练习记录）、
  `takes/`（我的录音：每段一个 m4a 和一个记录混音设置的 json）。
  以前的版本导入的歌还有一份 `original.*`（原文件的副本），现在不再保存，也没有地方用到它。
- 导出的成品在 App 的 Documents 目录，“文件”App 里显示为 我的 iPhone › 音迹。
- 发给别人的歌曲文件（`.yintrace`，`lib/src/library/song_package.dart`）也导出到 Documents 目录。
  格式：12 字节 `YinTraceSong`、容器版本（u32 小端，现在是 1）、清单长度（u32 小端）、清单（UTF-8 JSON：
  歌名、歌手、时长、歌词，以及每个文件的角色、大小和 SHA-256），后面依次是各个文件：
  `reference.json`、`pitch.bin`、人声、伴奏。`history.json` 和 `takes/` 不在里面，
  `song.json` 里的分数和练习次数也不写进清单。导入时文件名由 App 自己定（只沿用音频的扩展名），
  不认识的角色跳过，大小或 SHA-256 对不上就整首不导入。
- 模型在 Application Support 目录 `models/`（不参与 iCloud 备份）。

## 测试

```bash
# 避免 Flutter 云元数据检测、Flutter/Dart 和 ORT 遥测；后续命令保持这些变量
export BOT=true CI=true FLUTTER_SUPPRESS_ANALYTICS=true ORT_DISABLE_TELEMETRY=1
flutter config --no-analytics
dart --disable-analytics

# 原生音频核心（C）：引擎混音/定位/循环/采集打点、null 设备、wav/mp3/flac 解码
packages/yintrace_audio/tool/run_native_tests.sh

# 编译宿主平台的原生库，然后跑 Dart 测试（包括用真实原生引擎驱动的练习页端到端测试）
cmake -S packages/yintrace_audio/src -B build/host -DCMAKE_BUILD_TYPE=Release && cmake --build build/host
pip install onnxruntime numpy   # 音高模型的测试用 Python 的 ONNX Runtime 运行它（flutter test 加载不了插件）
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so flutter test
# 加上 SCREENSHOT_DIR=build/screenshots 会把界面截图写出来；PYTHON=... 指定带 onnxruntime 的 Python，
# 没有时音高模型的真实测试会跳过

# 随 App 附带的音高模型：确认它就是脚本从 swift-f0 官方 wheel 生成的（需要 pip install onnx）
python tools/build_pitch_model.py verify

# 模型配方：随机权重的往返自检；用真实模型按配方组装并与 PyTorch 对照
python tools/build_karaoke_graph.py selftest
tools/fetch_models.sh build/uvr-models
python tools/build_karaoke_graph.py verify build/uvr-models/6_HP-Karaoke-UVR.pth
# Dart 侧用同一份配方组装真实模型并核对 SHA-256
MODELS_DIR=$PWD/build/uvr-models flutter test test/models_test.dart
# 用 App 自己的下载代码从官方地址下载、校验、组装（194 MB）
LIVE_MODEL_DOWNLOAD=1 flutter test test/models_test.dart
```

**真机测速**：测导入一首歌的实际耗时，并比较 CPU 与 Core ML 的速度、内存和结果差异。
只有手机时，装 CI 产出的测试版（设置里多一个“性能测试”），测完复制报告，见
[只用 iPhone 测试](phone-testing.md)；有 Mac 时也可以运行 `tools/device_benchmark.sh <设备 ID>`，
生成 `build/device-benchmark.md`，见 [真机测速](device-benchmark.md)。两者是同一份测速代码
（`lib/src/benchmark/`）。

`.github/workflows/ci.yml` 在 Linux 上跑以上测试，在 macOS 上做 **iOS 无签名归档**
（测试版，打包成未签名的 `YinTrace-test-unsigned.ipa` 作为构建产物，自己用 Apple ID 签名安装）、
iPhone 模拟器真实插件冒烟（两个真实模型、AAC 往返、AGPL 全文和进程峰值），
并测试 Core Audio 解码与 AAC 编码；不再构建未适配的 macOS App。
模拟器不替代真机，见 [iOS 验收清单](ios-validation.md)。
Linux 上还构建 Android release APK（构建产物 `yintrace-android-apk`，调试密钥签名），
并在 Android 14 模拟器上跑 `integration_test/android_smoke_test.dart`：m4a 与 ADTS 的 AAC 解码
（含编码器延迟的裁剪）、运行时麦克风授权（`tools/ci_android_allow_microphone.py` 代按“允许”）。
测试音频由 `tools/make_android_fixtures.sh` 生成。

可选的整曲端到端测试（音频和歌词仅保存在本地，不要提交）：

```bash
MODELS_DIR=$PWD/build/uvr-models REAL_IMPORT_AUDIO=/path/to/mix.wav \
REAL_IMPORT_LYRICS=/path/to/lyrics.lrc PYTHON=python \
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so \
flutter test test/real_import_test.dart
```

它运行完整 ImportPipeline，检查保存音频及逐字音高图的时序、音高和覆盖。
提供 `REAL_IMPORT_REFERENCE=/path/to/uvr_lead.wav` 时还与 UVR 主唱生成的图比较；
`REAL_IMPORT_OUT` 可保留本地曲库输出。CI 使用原创示例歌词和合成音频验证此路径。

## 发布新版本

App 的“检查更新”读取 GitHub 上的最新 Release（`api.github.com/repos/zhikkz/YinTrace/releases/latest`，
不含草稿和预发布），把它的 tag 和 App 自己的版本比较。发布时：

1. 同时改 `pubspec.yaml` 的 `version` 和 `lib/src/app/licenses.dart` 的 `appVersion`（有测试保证两者一致）。
2. 在 GitHub 发布 Release，tag 写成 `v` 加版本号，例如 `v1.1.0`，把安装包附在这个 Release 上。

已装的 App 每天最多自动查一次（关于页可关），发现更高的版本时，只在曲库的设置按钮、设置里的“关于音迹”
和关于页显示红点，不弹窗；打开关于页后前两处的红点消失，关于页里提供该 Release 页面的链接。
还没有任何 Release 时，GitHub 返回 404，App 显示“已是最新版本”。

## 移植到其他平台

代码按“与平台无关的 Dart + 可移植的 C 核心”组织，iOS 以外的平台需要补的东西：

| 平台 | 已经可用 | 还需要 |
|---|---|---|
| macOS | 原生核心（Core Audio、权限）、权限声明 | 实机测试 |
| Android | 原生核心（AAudio/OpenSL，CMake 构建）、ONNX Runtime 插件、运行时申请麦克风权限、m4a/AAC 解码（NDK MediaCodec；wav/mp3/flac 仍走 miniaudio） | 实机测试；aiff/caf 解码；AAC 编码（目前分离结果存 WAV） |
| Windows | 原生核心（WASAPI，CMake 构建）、ONNX Runtime 插件 | m4a 解码（Media Foundation）；实机测试 |

非 Apple 平台没有 AAC 编码器时，分离结果会自动保存为 WAV。
