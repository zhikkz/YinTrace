# YinTrace 唱歌练习

YinTrace 是一个跨平台（Flutter）的唱歌练习软件。当前只适配 **iOS**，代码结构为
Windows / macOS / Android 保留了可移植性。

它做三件事：

1. **人声拆分**：导入一首歌，先用 `UVR-MDX-NET-Voc_FT` 分离出人声，再用
   `6_HP-Karaoke-UVR` 去掉和声，得到纯净的主唱人声。全部在手机本地完成。
2. **逐字逐句音高图**：根据你输入的带时间歌词（`[00:12.40]夜里的风慢慢吹过窗台`），
   测量纯人声里每一句、每一个字的音高，在音高表里画出一段一段的线条，并保存在本地曲库。
3. **演唱练习（主打功能）**：像 Pitch Witch 一样用 **YIN 算法**实时分析你唱的音高，
   和第 2 步生成的逐字音高图对齐显示，唱完告诉你哪个字唱高了、唱低了、没唱出来、
   不稳、抢拍或进晚了，可以单句循环练到唱准为止。

界面：曲库（本地多首歌、最高分）→ 歌曲页（每句一张逐字音高图）→ 练习页（滚动的参考音符 +
你的实时音高轨迹 + 卡拉 OK 歌词）→ 评分（每个字的问题、单句循环入口）。CI 会把测试中渲染的
界面截图作为 `screenshots` 产物上传。

---

## 目录

- [快速开始（iOS）](#快速开始ios)
- [准备分离模型](#准备分离模型)
- [使用说明](#使用说明)
- [歌词格式](#歌词格式)
- [工作原理](#工作原理)
- [项目结构](#项目结构)
- [测试](#测试)
- [移植到其他平台](#移植到其他平台)
- [已知限制](#已知限制)
- [致谢与第三方许可](#致谢与第三方许可)

---

## 快速开始（iOS）

需要：一台 Mac，Xcode 16 或更新版本，Flutter 3.47（stable），CocoaPods，一部 iOS 16+ 的 iPhone。

```bash
git clone https://github.com/zhikkz/YinTrace.git
cd YinTrace
flutter pub get
cd ios && pod install && cd ..
open ios/Runner.xcworkspace      # 在 Signing & Capabilities 里选择你的开发者团队
flutter run --release            # 连接 iPhone 后运行（人声分离很吃性能，请用 release）
```

- 部署目标是 iOS 16.0（ONNX Runtime 插件的要求）。
- 第一次练习时系统会请求**麦克风权限**。
- 所有插件都通过 CocoaPods 集成（`pubspec.yaml` 里关闭了 Swift Package Manager）。

## 准备分离模型

模型文件很大（每个 60–130 MB），不包含在仓库里。你已经下载好的两个模型需要这样处理：

| 模型 | 原始文件 | App 需要的文件 |
|---|---|---|
| 人声分离 | `UVR-MDX-NET-Voc_FT.onnx` | 原文件 + `UVR-MDX-NET-Voc_FT.json` |
| 去和声 | `6_HP-Karaoke-UVR.pth`（PyTorch） | **转换后的** `6_HP-Karaoke-UVR.onnx` + `.json` |

`6_HP-Karaoke-UVR.pth` 是 PyTorch 权重，手机上的 ONNX Runtime 不能直接加载，
需要在电脑上转换一次：

```bash
pip install torch onnx onnxscript onnxruntime numpy
python tools/prepare_models.py mdx ~/Downloads/UVR-MDX-NET-Voc_FT.onnx --out-dir build/models
python tools/prepare_models.py vr  ~/Downloads/6_HP-Karaoke-UVR.pth   --out-dir build/models
```

转换脚本会：

- 按 UVR 的方式计算模型哈希，查出它的频带配置（6_HP-Karaoke 属于 UVR 的两种
  karaoke 配置之一：`4band_v2_sn` 或 `3band_44100_msb2`），也可以用 `--param` 手动指定；
- 按文件大小选择 UVR 的网络结构（VR v5 / v5.1），重建网络并加载权重；
- 导出 ONNX（输入 `[1, 2, bins+1, 512]` 的幅度谱，输出掩码），并和 PyTorch 的结果逐元素比对；
- 写出同名 `.json`，里面是 App 做前后处理需要的全部参数。

然后把 `build/models` 里的 4 个文件放进 App，任选一种方式：

1. App 里 **设置 → 导入模型文件**（可多选 `.onnx` 和 `.json`）；
2. 用 iPhone 的“文件”App 或 Mac 的访达，把它们拷到 **YinTrace → models** 文件夹；
3. 放进仓库的 `assets/models/` 再构建，App 首次启动时会自动安装（会让安装包变大）。

> 只有纯人声、不需要分离的歌，可以完全不导入模型（导入时打开“这已经是分离好的纯人声”）。

## 使用说明

1. **导入歌曲**：曲库页点“导入歌曲”，选择音频（mp3 / m4a / wav / flac / aiff …），
   填写歌名，粘贴带时间的歌词，点“分离人声并生成音高图”。
   - 处理在后台线程进行，进度条会显示当前阶段（读取 → 分离人声 → 去和声 → 测音高 → 逐字对齐 → 保存）
     和剩余时间。一首 4 分钟的歌在新款 iPhone 上大约需要几分钟，请保持 App 在前台。
   - 已经是纯人声的文件可以跳过分离，并可另外选择一个伴奏文件用于练习。
2. **查看音高图**：歌曲页按句列出逐字音高图——每个字是一段（或几段，转音时）横线，
   字写在线条上方，细线是原唱的真实音高曲线。歌词写错了可以在菜单里“修改歌词 / 重新对齐”，
   不需要重新分离。
3. **练习**：点“整首练习”或点某一句进入单句循环。
   - 播放的是去掉主唱后的伴奏（保留和声），可以在 ⚙ 里调伴奏和原唱导唱的音量。
   - 中间的音高图随音乐滚动，竖线是当前位置；你的声音实时画成轨迹：
     **绿色**=准（默认 ±50 音分），**黄色**=接近，**红色**=偏差大。唱过的字会按得分变色。
   - 顶部显示目标音、你的音和偏差（高/低多少音分）。
   - 点右上角的评分按钮或唱完整首，会看到总分、每句得分，以及“需要加强的字”
     （偏高 / 偏低 / 没唱出来 / 不稳 / 抢拍 / 进晚了）。点任意一句就进入该句的循环练习。
   - 每次练习都会保存到这首歌的练习记录里。
4. **自由练习**：曲库右上角的波形按钮，是一个实时音高监视器（类似 Pitch Witch），
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
   ├─► MDX-Net Voc_FT：STFT(7680/1024) → [1,4,3072,256] → ONNX → iSTFT，
   │   分块 + Hann 重叠相加（UVR demix 的移植）                  ──► 人声
   │
   ├─► VR 6_HP-Karaoke：多频带 STFT + 重采样拼接 → 幅度归一化 → 512 帧窗口 →
   │   ONNX 掩码 → aggressiveness → (1-mask)·X → 分频带 iSTFT 合成  ──► 主唱
   │                                                            伴奏 = 原曲 − 主唱
   ├─► YIN（22.05 kHz，1024 点窗，5.8 ms 步长）+ 电平门限、八度纠错、中值滤波 ──► 音高曲线
   │
   └─► 逐字对齐：每句在时间戳附近找有声区域；用动态规划把 N 个字放到
       声母间隙 / 能量凹陷 / 音高跳变 等“音节起点”上，同时约束时长合理；
       每个字内部再切成稳定的音符                                ──► 逐字音高图（本地保存）

练习：全双工音频引擎（播放伴奏 + 采集麦克风，同一回调）给每个采集块打上
“当时正在播放的歌曲帧号”，减去系统延迟后 → 实时 YIN（2048 点窗、10 ms 步长）
→ 与该时刻的参考音符比较（可忽略八度）→ 每个字的覆盖率、音分偏差中位数、
稳定度、起唱时间 → 评分与问题标签。
```

关键实现细节：

- **分离结果与 UVR 一致**：`tools/reference/make_separation_fixtures.py` 直接运行 UVR 自己的
  `spec_utils.py` 和 MDX `demix` 代码，测试用相同的确定性“假模型”比对 Dart 实现，
  两种 karaoke 频带配置、两个 stem 的误差都在 2e-4 以内；长音频分段处理与整段处理的 SNR > 40 dB。
- **手机内存**：VR 按 30 秒分段（带 3 秒上下文和交叉淡化）处理，幅度归一化使用全曲最大值（与 UVR 相同）。
- **STFT / 重采样**：与 `torch.stft`、`librosa.stft`、`scipy.signal.resample_poly` 的数值一致（有测试）。
- **YIN**：差分函数用 FFT 互相关计算（O(N log N)），带抛物线插值。
- **同步**：伴奏播放和麦克风采集在同一个音频回调里完成，所以每个采集样本都能精确对应到歌曲位置，
  单句循环跳回时也不会错位。

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
    app/          设置、模型管理、全局服务
    ui/           曲库 / 导入 / 歌曲 / 练习 / 评分 / 自由练习 / 设置 页面，音高图绘制
packages/yintrace_audio/   原生音频核心（C + miniaudio，dart:ffi）
  src/yt_audio.c            解码、全双工练习引擎、采集环形缓冲（带歌曲帧号）
  src/yt_platform_apple.inc AVAudioSession、麦克风权限、ExtAudioFile 解码、AAC 编码
tools/
  prepare_models.py         模型准备：VR .pth → ONNX、生成配置
  uvr_model_data.json       UVR 的模型哈希表与频带配置
  reference/                生成测试参考数据的脚本（numpy / torch / librosa / UVR 原代码）
test/                       单元测试、对照测试、端到端 UI 测试
```

本地数据：

- 曲库在 App 的 Application Support 目录 `songs/<id>/`：`song.json`（信息与歌词）、
  `reference.json`（逐字音高图）、`pitch.bin`（音高曲线）、`vocals.m4a`（主唱）、
  `accompaniment.m4a`（伴奏）、`original.*`（原文件）、`history.json`（练习记录）。
- 模型在 Documents 目录 `models/`（“文件”App 可见）。

## 测试

```bash
# 原生音频核心（C）：引擎混音/定位/循环/采集打点、null 设备、wav/mp3/flac 解码
packages/yintrace_audio/tool/run_native_tests.sh

# 编译宿主平台的原生库，然后跑 Dart 测试（包括用真实原生引擎驱动的练习页端到端测试）
cmake -S packages/yintrace_audio/src -B build/host -DCMAKE_BUILD_TYPE=Release && cmake --build build/host
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so flutter test
# 加上 SCREENSHOT_DIR=build/screenshots 会把界面截图写出来

# 模型转换工具自检（随机权重，验证网络结构与 ONNX 导出）
python tools/prepare_models.py selftest
```

`.github/workflows/ci.yml` 在 Linux 上跑以上测试，并在 macOS 上做 **iOS 无签名构建** 和
macOS 构建（同时在 macOS 上测试 Core Audio 的解码与 AAC 编码路径）。

## 移植到其他平台

代码按“与平台无关的 Dart + 可移植的 C 核心”组织，iOS 以外的平台需要补的东西：

| 平台 | 已经可用 | 还需要 |
|---|---|---|
| macOS | 原生核心（Core Audio、权限）、权限声明 | 实机测试 |
| Android | 原生核心（AAudio/OpenSL，CMake 构建）、ONNX Runtime 插件、录音权限声明 | 运行时申请麦克风权限；m4a/AAC 解码（目前 Android 只能解码 wav/mp3/flac） |
| Windows | 原生核心（WASAPI，CMake 构建）、ONNX Runtime 插件 | m4a 解码（Media Foundation）；实机测试 |

非 Apple 平台没有 AAC 编码器时，分离结果会自动保存为 WAV。

## 已知限制

- **逐字对齐是启发式的**（声母间隙、能量凹陷、音高跳变 + 动态规划），没有用语音识别模型。
  连续浊辅音（m、n、l、y、w 开头）多的句子、转音很多的长拖腔可能会切偏，
  可以通过修正歌词时间或在空格处断句改善。歌词时间戳越准，结果越好。
- 人声分离在手机 CPU 上需要几分钟；可以在设置里试试 Core ML 加速（不兼容时自动回退 CPU）。
- 分离和去和声的质量取决于 UVR 模型本身；有残留伴奏的段落会被电平门限过滤，可能少测到个别字。
- 练习时外放会让麦克风录到伴奏，请尽量戴耳机。
- 这个仓库里的 iOS 部分在 Linux 环境中开发，C/Objective-C 代码无法在本地编译验证，
  请以 CI 的 iOS 构建结果和实机运行为准。

## 致谢与第三方许可

见 [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md)。分离算法的前后处理移植自
[Ultimate Vocal Remover GUI](https://github.com/Anjok07/ultimatevocalremovergui)（MIT），
模型 `UVR-MDX-NET-Voc_FT` 与 `6_HP-Karaoke-UVR` 来自 UVR 项目，使用时请注明 UVR 及其作者。
