# YinTrace 唱歌练习

YinTrace 是一个跨平台（Flutter）的唱歌练习软件。当前只适配 **iOS**，代码结构为
Windows / macOS / Android 保留了可移植性。

它做三件事：

1. **人声拆分**：导入一首歌，先用 `UVR-MDX-NET-Voc_FT` 分离出人声，再用
   `6_HP-Karaoke-UVR` 去掉和声，得到纯净的主唱人声。全部在手机本地完成。
2. **逐字逐句音高图**：根据你输入的带时间歌词（`[00:12.40]夜里的风慢慢吹过窗台`），
   测量纯人声里每一句、每一个字的音高，在音高表里画出一段一段的线条，并保存在本地曲库。
3. **演唱练习（主打功能）**：用 **YIN 算法**实时分析你唱的音高，
   和第 2 步生成的逐字音高图对齐显示，唱完告诉你哪个字唱高了、唱低了、没唱出来、
   不稳、抢拍或进晚了，可以单句循环练到唱准为止。

界面：曲库（本地多首歌、最高分）→ 歌曲页（每句一张逐字音高图）→ 练习页（滚动的参考音符 +
你的实时音高轨迹 + 卡拉 OK 歌词）→ 评分（每个字的问题、单句循环入口）。CI 会把测试中渲染的
界面截图作为 `screenshots` 产物上传。

---

## 目录

- [快速开始（iOS）](#快速开始ios)
- [分离模型](#分离模型)
- [使用说明](#使用说明)
- [歌词格式](#歌词格式)
- [工作原理](#工作原理)
- [项目结构](#项目结构)
- [测试](#测试)
- [移植到其他平台](#移植到其他平台)
- [已知限制](#已知限制)
- [许可](#许可)
- [致谢](#致谢)

---

## 快速开始（iOS）

需要：一台 Mac，Xcode 16 或更新版本，Flutter 3.47.9（stable），CocoaPods，一部 iOS 16+ 的 iPhone。

```bash
git clone https://github.com/zhikkz/YinTrace.git
cd YinTrace
export BOT=true CI=true FLUTTER_SUPPRESS_ANALYTICS=true ORT_DISABLE_TELEMETRY=1
flutter config --no-analytics
dart --disable-analytics
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace      # 在 Signing & Capabilities 里选择你的开发者团队
flutter run --release            # 连接 iPhone 后运行（人声分离很吃性能，请用 release）
```

- 部署目标是 iOS 16.0（ONNX Runtime 插件的要求）。
- 第一次练习时系统会请求**麦克风权限**。
- 所有插件都通过 CocoaPods 集成（`pubspec.yaml` 里关闭了 Swift Package Manager）。

## 分离模型

YinTrace 只用 Ultimate Vocal Remover 的两个模型，**不需要你手动准备**：第一次导入整首歌时，
App 会提示下载（一共 194 MB，只下载一次，支持断点续传），下载后校验 SHA-256。

| 用途 | 模型 | 下载的文件 | 大小 |
|---|---|---|---|
| 人声分离 | UVR-MDX-NET Voc FT | `UVR-MDX-NET-Voc_FT.onnx` | 67 MB |
| 去和声 | 6_HP-Karaoke-UVR | `6_HP-Karaoke-UVR.pth` | 127 MB |

下载地址是 UVR 官方模型库（`github.com/TRvlvr/model_repo` 的 release）。权重文件不在这个仓库里，
也不打包进 App。

- MDX 官方文件在安装时用 6 字节的配方将输入/输出时间轴改为动态，权重不变。
  默认 segment size 为 128、重叠 0.5；较短上下文会改变分离结果。
- `6_HP-Karaoke-UVR.pth` 是 PyTorch 权重，手机上的 ONNX Runtime 不能直接读。App 里带了这个网络的
  结构（约 136 KB）和一份“拷贝配方”，下载完成后按配方从 `.pth` 里把每个权重张量的字节拷出来，
  拼成动态时间轴 ONNX 模型——不需要 PyTorch，结果和在电脑上用 PyTorch 导出的逐字节相同
  （见 `assets/models/README.md` 和 `tools/build_karaoke_graph.py`）。
- 网络连不上 GitHub 时，可以用别的办法把这两个文件弄到手机上，然后在下载窗口里点
  “已经有这两个文件？从‘文件’里选”。App 按内容（SHA-256）识别，只接受这两个原版文件。
- 模型保存在 App 的 Application Support 目录，不参与 iCloud 备份；可以在设置里删除以腾出空间，
  已经导入的歌不受影响。
- 只有纯人声、不需要分离的歌，完全不需要模型（导入时打开“这是已经分离好的纯人声”）。

## 使用说明

1. **导入歌曲**：曲库页点“导入歌曲”，选择音频（mp3 / m4a / wav / flac / aiff …），
   填写歌名，粘贴带时间的歌词，点“分离人声，生成音高图”。第一次会先提示下载分离模型。
   - 处理在后台线程进行，进度条会显示当前阶段（读取 → 分离人声 → 去和声 → 测音高 → 逐字对齐 → 保存）
     和实际已用时间。耗时取决于设备、曲长和分段参数，尚无 iPhone 实测；请保持 App 在前台。
   - 已经是纯人声的文件可以跳过分离，并可另外选择一个伴奏文件用于练习。
2. **查看音高图**：歌曲页按句列出逐字音高图——每个字是一段（或几段，转音时）横线，
   字写在线条上方，细线是原唱的真实音高曲线。歌词写错了可以在菜单里“修改歌词 / 重新对齐”，
   不需要重新分离。
3. **练习**：点“整首练习”或点某一句进入单句循环。
   - 播放的是去掉主唱后的伴奏（保留和声），可以在 ⚙ 里调伴奏和原唱导唱的音量。
   - 中间的音高图随音乐滚动，竖线是当前位置；你的声音实时画成轨迹：
     **石绿**=准（默认 ±50 音分），**石青**=偏低，**朱砂**=偏高，接近时混入藤黄。唱过的字会按得分变色。
   - 顶部显示目标音、你的音和偏差（高/低多少音分）。
   - 点右上角的评分按钮或唱完整首，会看到总分、每句得分，以及“需要加强的字”
     （偏高 / 偏低 / 没唱出来 / 不稳 / 抢拍 / 进晚了）。点任意一句就进入该句的循环练习。
   - 查看评分或唱完后保存练习记录。切后台、锁屏、来电或切换耳机时暂停播放和采集，
     返回后点播放继续；自由练习返回后点“继续练习”。
4. **自由练习**：曲库右上角的波形按钮，是一个实时音高监视器，
   显示音名、频率、简谱唱名、音分偏差和滚动的音高轨迹。

**建议戴耳机练习**：外放时麦克风会录到伴奏和导唱，音高检测会受干扰。
**延迟**：App 会读取系统报告的输入/输出延迟并自动补偿；如果你的轨迹总比参考线偏右（晚），
在设置里把“延迟补偿”调大（蓝牙耳机通常需要 +150～250 ms）。

## 歌词格式

```
[00:12.40]夜里的风慢慢吹过窗台
[00:17.95]远处的灯一盏一盏亮开
[00:35.80]下雨了 记得带伞
```

- 每行 `[分:秒.百分秒]歌词`，时间是这一句**开始唱**的时刻（毫秒 `.123` 也可以）。
- 每个汉字（以及假名、韩文音节）是一个单位；英文按单词。标点会被忽略。
- **空格表示停顿**，对齐时会优先在空格处找换气点。
- 也支持标准 LRC 的扩展：一行多个时间 `[00:12.00][01:30.00]副歌`、`[offset:+200]`、
  `[ti:歌名]` 等标签、只有时间没有歌词的行（表示上一句结束），以及逐字时间 `<00:12.30>字`
  （有逐字时间时会直接使用）。

## 工作原理

```
音频文件 ──► 解码 (Core Audio / miniaudio) ──► 44.1 kHz 立体声
   │
   ├─► MDX-Net Voc_FT：STFT(7680/1024) → [1,4,3072,128] → ONNX → iSTFT，
   │   分块 + Hann 重叠相加（UVR demix 的移植）                  ──► 人声
   │
   ├─► VR 6_HP-Karaoke：多频带 STFT + 重采样拼接 → 幅度归一化 → 320 帧窗口 →
   │   ONNX 掩码 → aggressiveness → (1-mask)·X → 分频带 iSTFT 合成  ──► 主唱
   │                                                            伴奏 = 原曲 − 主唱
   ├─► YIN（22.05 kHz，1024 点窗，5.8 ms 步长）+ 电平门限、八度纠错、中值滤波 ──► 音高曲线
   │
   └─► 逐字对齐：整首歌所有字放进同一个动态规划里一起对齐。每句的时间戳是“软锚点”
       （允许早 0.5 秒、晚 1 秒，越偏离代价越大），所以时间戳不准、上下句连着唱
       都不会错位；按每个字的拼音声母预测音节起点的样子（b/p/sh… 有清辅音间隙，
       m/n/l/r 是音量凹陷，元音/y/w 开头看音高变化）；只把和这个字连着的发声算进
       它的时长；每个字内部再切成稳定的音符                    ──► 逐字音高图（本地保存）

练习：全双工音频引擎（播放伴奏 + 采集麦克风，同一回调）给每个采集块打上
“当时正在播放的歌曲帧号”，减去系统延迟后 → 实时 YIN（2048 点窗、10 ms 步长）
→ 与该时刻的参考音符比较（可忽略八度）→ 每个字的覆盖率、音分偏差中位数、
稳定度、起唱时间 → 评分与问题标签。
```

关键实现细节：

- **分离结果与 UVR 一致**：`tools/reference/make_separation_fixtures.py` 直接运行 UVR 自己的
  `spec_utils.py` 和 MDX `demix` 代码，测试用相同的确定性“假模型”比对 Dart 实现，
  两种 karaoke 频带配置、两个 stem 的误差都在 2e-4 以内；长音频分段处理与整段处理的 SNR > 40 dB。
  真实两个模型也按当前分段参数对照：14 秒合成混音上，MDX 信号/差值比 117.7 dB，
  VR 主唱 126.5 dB、被移除部分 110.2 dB，详见[验证记录](docs/inference-memory.md)。
- **内存**：MDX 单块滚动累加，VR 期间释放混音，结束后重新解码并复用为伴奏缓冲。VR 按 12 秒分段（带 3 秒上下文和交叉淡化），
  幅度归一化使用全曲最大值。两个模型顺序加载、关闭，CPU arena 关闭；Apple 插件为此带有本地补丁。
  桌面独立推理峰值 MDX 约 488 MB、VR 约 816 MB；整进程在 iPhone 上的 1.5 GB 目标仍需实测。
- **STFT / 重采样**：与 `torch.stft`、`librosa.stft`、`scipy.signal.resample_poly` 的数值一致（有测试）。
- **YIN**：差分函数用 FFT 互相关计算（O(N log N)），带抛物线插值。
- **同步**：伴奏播放和麦克风采集在同一个音频回调里完成，所以每个采集样本都能精确对应到歌曲位置，
  单句循环跳回时也不会错位。

## 界面设计

配色取自中国画的矿物颜料，每种颜色只表达一个意思：墨（文字、原唱旋律、主要按钮）、
宣纸（底色，像乐谱纸）、石绿（唱准 / 好）、朱砂（唱高了 / 差）、石青（唱低了）、
藤黄（接近 / 不稳）。练习时你的声音轨迹按音分偏差在 石青 → 石绿 → 朱砂 之间连续变色，
一眼就能看出是高了还是低了，而不只是对错。逐字音高图像乐谱一样排版：每个字的音是一笔墨线，
字写在线上方；评分页把需要加强的字做成大字卡片。支持深色模式。

`test/design_preview_test.dart` 可以用一首真实歌曲渲染所有页面的截图（浅色 / 深色），
方便检查设计：

```bash
DESIGN_SONG_DIR=<含 reference.json、pitch.bin、vocal.wav 的目录> DESIGN_LYRICS=<歌词.lrc> \
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so SCREENSHOT_DIR=build/design flutter test test/design_preview_test.dart
```

`test/real_vocal_test.dart` 对任意纯人声 + 歌词跑一遍音高分析和逐字对齐，并输出每个字的时间
（`REAL_VOCAL=人声.wav REAL_LYRICS=歌词.lrc REAL_OUT=输出目录`）。

## 项目结构

```
lib/
  main.dart
  src/
    dsp/          实数 FFT、STFT/iSTFT、多相重采样、YIN、音高换算
    separation/   MDX-Net 与 VR 推理流程（UVR 移植）、模型配置、ONNX Runtime 封装
    analysis/     LRC 解析、离线音高跟踪、逐字对齐、参考旋律数据结构
    import/       导入流水线（后台 isolate）
    library/      本地曲库（每首歌一个目录）与练习记录
    practice/     实时音高跟踪、评分、练习会话
    models/       两个分离模型的下载、校验、动态时间轴配方与 .pth → ONNX 组装
    app/          设置、全局服务、第三方许可登记
    ui/           曲库 / 导入 / 歌曲 / 练习 / 评分 / 自由练习 / 设置 页面，音高图绘制
packages/flutter_onnxruntime/ 固定 1.9.0 的本地副本，补齐 Apple useArena（保留 MIT 许可）
packages/yintrace_audio/   原生音频核心（C + miniaudio，dart:ffi）
  src/yt_audio.c            解码、全双工练习引擎、采集环形缓冲（带歌曲帧号）
  src/yt_platform_apple.inc AVAudioSession、麦克风权限、ExtAudioFile 解码、AAC 编码
tools/
  build_karaoke_graph.py    生成 assets/models 里的网络结构和拷贝配方，并与 PyTorch 对照验证
  fetch_models.sh           给测试和工具用：下载两个模型并校验
  reference/                生成测试参考数据的脚本（numpy / torch / librosa / UVR 原代码）
test/                       单元测试、对照测试、端到端 UI 测试
```

本地数据：

- 曲库在 App 的 Application Support 目录 `songs/<id>/`：`song.json`（信息与歌词）、
  `reference.json`（逐字音高图）、`pitch.bin`（音高曲线）、`vocals.m4a`（主唱）、
  `accompaniment.m4a`（伴奏）、`original.*`（原文件）、`history.json`（练习记录）。
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
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so flutter test
# 加上 SCREENSHOT_DIR=build/screenshots 会把界面截图写出来

# 模型配方：随机权重的往返自检；用真实模型按配方组装并与 PyTorch 对照
python tools/build_karaoke_graph.py selftest
tools/fetch_models.sh build/uvr-models
python tools/build_karaoke_graph.py verify build/uvr-models/6_HP-Karaoke-UVR.pth
# Dart 侧用同一份配方组装真实模型并核对 SHA-256
MODELS_DIR=$PWD/build/uvr-models flutter test test/models_test.dart
# 用 App 自己的下载代码从官方地址下载、校验、组装（194 MB）
LIVE_MODEL_DOWNLOAD=1 flutter test test/models_test.dart
```

`.github/workflows/ci.yml` 在 Linux 上跑以上测试，在 macOS 上做 **iOS 无签名归档**、
iPhone 模拟器真实插件冒烟（两个真实模型、AAC 往返、AGPL 全文和进程峰值），
并测试 Core Audio 解码与 AAC 编码；不再构建未适配的 macOS App。
模拟器不替代真机，见 [iOS 验收清单](docs/ios-validation.md)。

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

## 移植到其他平台

代码按“与平台无关的 Dart + 可移植的 C 核心”组织，iOS 以外的平台需要补的东西：

| 平台 | 已经可用 | 还需要 |
|---|---|---|
| macOS | 原生核心（Core Audio、权限）、权限声明 | 实机测试 |
| Android | 原生核心（AAudio/OpenSL，CMake 构建）、ONNX Runtime 插件、录音权限声明 | 运行时申请麦克风权限；m4a/AAC 解码（目前 Android 只能解码 wav/mp3/flac） |
| Windows | 原生核心（WASAPI，CMake 构建）、ONNX Runtime 插件 | m4a 解码（Media Foundation）；实机测试 |

非 Apple 平台没有 AAC 编码器时，分离结果会自动保存为 WAV。

## 已知限制

- **逐字对齐是启发式的**（拼音声母先验 + 清辅音间隙 / 音量凹陷 / 音高变化 + 全曲动态规划），
  没有用语音识别模型。用一首真实歌曲的纯人声（259.6 秒，36 句，315 个歌词单位）检查过：每句都对到了正确的
  起点，没有测不到音高的字；但两个字唱在同一个长音里、中间没有任何辅音痕迹时，
  边界仍可能差一个字。在这种地方加一个空格（表示停顿）或修正时间戳可以改善。
- 暂无 iPhone 速度数据。本次桌面 14 秒合成混音 MDX 约 17.2 秒、VR 约 24.5 秒，
  短片 padding 较多，不能据此保证整曲或手机耗时。较小 VR 窗口降低内存，但推理次数增多。
- 发布路径只用 CPU；Core ML 开关已移除，避免暴露未经设备验证的加速选项。
- 解码和 VR 输入/输出仍随曲长占内存，尚未做到整条流水线流式处理。
- 分离和去和声的质量取决于 UVR 模型本身；有残留伴奏的段落会被电平门限过滤，可能少测到个别字。
- 练习时外放会让麦克风录到伴奏，请尽量戴耳机。
- 这个仓库里的 iOS 部分在 Linux 环境中开发，C/Objective-C 代码无法在本地编译验证，
  CI 新增了模拟器冒烟，但麦克风授权、音频中断、耳机路由、延迟和长歌曲峰值仍须真机验收。

## 许可

YinTrace 是自由软件，按 **GNU Affero 通用公共许可证第 3 版（AGPL-3.0）** 发布，全文见 [LICENSE](LICENSE)。

```
YinTrace - 唱歌练习软件
Copyright (C) 2026 zhikkz

This program is free software: you can redistribute it and/or modify it under
the terms of the GNU Affero General Public License as published by the Free
Software Foundation, version 3.

This program is distributed in the hope that it will be useful, but WITHOUT
ANY WARRANTY; without even the implied warranty of MERCHANTABILITY or FITNESS
FOR A PARTICULAR PURPOSE. See the GNU Affero General Public License for more
details.
```

简单说：你可以自由使用、研究、修改和再分发；但只要你分发它（包括改过的版本、编译好的安装包），
或者用改过的版本通过网络对外提供服务，就必须以同样的 AGPL-3.0 许可向对方提供完整的源代码。

- 仓库里移植或引用的第三方部分（UVR 的分离算法和网络结构、miniaudio、pypinyin 的拼音数据等）
  原本是 MIT、BSD、Apache 2.0 或公有领域，都与 AGPL-3.0 兼容；它们的版权声明和许可全文保留在
  [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)，App 里在“设置 → 致谢与开源许可”也能看到。
- **模型不属于本项目，也不受这份许可约束**：`UVR-MDX-NET-Voc_FT` 和 `6_HP-Karaoke-UVR` 由
  Ultimate Vocal Remover 的开发者（Anjok07、aufr33）训练并发布，App 从 UVR 的官方模型库下载，
  仓库和安装包里都没有权重。UVR 要求使用其模型的第三方应用注明 UVR 及其开发者。
- 你导入的歌曲、歌词归各自的权利人所有，只保存在你的设备上；仓库里的示例歌词是为本项目写的。

## 致谢

分离算法的前后处理移植自
[Ultimate Vocal Remover GUI](https://github.com/Anjok07/ultimatevocalremovergui)（MIT），
其中 VR 架构来自 [tsurumeso/vocal-remover](https://github.com/tsurumeso/vocal-remover)，
MDX-Net 来自 [Kuielab / Woosung Choi](https://github.com/kuielab/mdx-net)。
音高检测是 YIN 算法（de Cheveigné & Kawahara, 2002）。完整列表见
[THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。
