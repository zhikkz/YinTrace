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
   不稳、抢拍或进晚了，可以单句循环练到唱准为止，也可以回听自己刚唱的，看每一句的得分趋势。
   不知道一句怎么唱，可以先“听这句原唱”。

另外：

- **中文、英文、日文歌**都能用：英文按单词、日文按假名对齐，日文汉字可以写读音。
- **校正音高**：某几个字的目标音识别错了，在歌曲页逐字听原唱、听目标音，升降半音或八度，
  或设成不计分。
- **制作成品**：把唱好的一遍配上伴奏和混响，导出 m4a，存到“文件”App 或直接分享。

界面：曲库（本地多首歌、最高分）→ 歌曲页（每句一张逐字音高图、校正音高、我的录音）→ 练习页
（滚动的参考音符 + 你的实时音高轨迹 + 卡拉 OK 歌词）→ 评分（每个字的问题、单句循环、回听、制作成品）。
CI 会把测试中渲染的界面截图作为 `screenshots` 产物上传。

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
- 上面是正式版。加上 `--dart-define=YINTRACE_TEST_BUILD=true` 是测试版（CI 产出的 `.ipa` 就是）：
  设置里多一组“测试版”（性能测试、只用备用线路重新下载模型），下载模型时显示用的是哪条线路。
  正式版里没有这些代码。
- 所有插件都通过 CocoaPods 集成（`pubspec.yaml` 里关闭了 Swift Package Manager）。

## 分离模型

YinTrace 只用 Ultimate Vocal Remover 的两个模型，**不需要你手动准备**：第一次导入整首歌时，
App 会提示下载（一共 194 MB，只下载一次，支持断点续传），下载后校验 SHA-256。

| 用途 | 模型 | 下载的文件 | 大小 |
|---|---|---|---|
| 人声分离 | UVR-MDX-NET Voc FT | `UVR-MDX-NET-Voc_FT.onnx` | 67 MB |
| 去和声 | 6_HP-Karaoke-UVR | `6_HP-Karaoke-UVR.pth` | 127 MB |

下载地址是 UVR 官方模型库（`github.com/TRvlvr/model_repo` 的 release）。连不上、服务器报错、
下载中断、半分钟内一直慢于 48 KB/秒，或者文件校验不对时，App 自动改用备用线路
`hf-mirror.com`（Hugging Face 镜像上 `Blane187/all_public_uvr_models` 固定提交的同名文件，
已核对与官方文件的大小和 SHA-256 相同），已下载的部分接着续传；两条线路都失败才报错，并写明两边各自的原因。
下一个文件先用刚才成功的线路。权重文件不在这个仓库里，也不打包进 App。

- MDX 官方文件在安装时用 6 字节的配方将输入/输出时间轴改为动态，权重不变。
  使用 UVR 可选的 segment size 128（UVR 默认 256）和 UVR 默认的重叠 0.25：内存约为 256 的一半，
  每秒音频的计算量还略少；较短的上下文会让分离结果和 256 略有不同（见[验证记录](docs/inference-memory.md)）。
- `6_HP-Karaoke-UVR.pth` 是 PyTorch 权重，手机上的 ONNX Runtime 不能直接读。App 里带了这个网络的
  结构（约 136 KB）和一份“拷贝配方”，下载完成后按配方从 `.pth` 里把每个权重张量的字节拷出来，
  拼成动态时间轴 ONNX 模型——不需要 PyTorch，结果和在电脑上用 PyTorch 导出的逐字节相同
  （见 `assets/models/README.md` 和 `tools/build_karaoke_graph.py`）。
- 两条线路都连不上时，可以用别的办法把这两个文件弄到手机上，然后在下载窗口里点
  “已经有这两个文件？从‘文件’里选”。App 按内容（SHA-256）识别，只接受这两个原版文件。
- 模型保存在 App 的 Application Support 目录，不参与 iCloud 备份；可以在设置里删除以腾出空间，
  已经导入的歌不受影响。
- 只有纯人声、不需要分离的歌，完全不需要模型（导入时打开“这是已经分离好的纯人声”）。

## 使用说明

1. **导入歌曲**：曲库页点“导入歌曲”，选择音频（mp3 / m4a / wav / flac / aiff …），
   填写歌名，粘贴带时间的歌词，点“分离人声，生成音高图”。第一次会先提示下载分离模型。
   - 处理在后台线程进行。进度条按实际计算量推进，显示当前阶段（读取 → 分离人声 → 去和声 → 测音高 →
     逐字对齐 → 保存）、模型已经跑了几次（如 37 / 118）、按这台设备的实测速度估算的剩余时间，
     以及每秒走动的已用时间，所以不会看起来像卡住。请保持 App 在前台。
   - 在 iPhone 上，人声分离用 GPU（Core ML）。每台设备第一次导入时先和 CPU 对比一段，结果一致才用；
     出错或不一致会自动改回 CPU。设置里的“用 GPU 加速人声分离”可以关掉。
   - 已经是纯人声的文件可以跳过分离，并可另外选择一个伴奏文件用于练习。
   - 采样率不是 44.1 kHz 的文件（比如 48 kHz 的 wav）先用带抗混叠滤波的多相重采样转换，
     高频不衰减，也不会多出原来没有的频率。
   - 导入完成后，曲库里只留分离出的人声和伴奏；你选的原文件不会再复制一份，
     选文件时系统给 App 的临时副本也会删掉。
2. **查看音高图**：歌曲页按句列出逐字音高图——每个字是一段（或几段，转音时）横线，
   字写在线条上方，细线是原唱的真实音高曲线。歌词写错了可以在菜单里“修改歌词 / 重新对齐”，
   不需要重新分离。
   - **校正音高**：点一句右边的笔（或菜单里的“校正音高”），选一个字：“听原唱”“听目标音”“一起听”，
     不一样就用“降八度 / 降半音 / 升半音 / 升八度”调到和原唱一样；原唱这里听不清、是念白或和声时，
     打开“这个字不计分”；没测到音高的字可以“加上目标音”再调。改动马上保存，练习和打分都用改过的；
     “恢复自动识别”随时退回。修改歌词重新对齐后，没改动的句子保留你的校正和练习分数——
     在它前面加一句、删一句也一样（按歌词内容对应，不按第几句）；删掉或改了字的句子，分数不再保留。
3. **练习**：点“整首练习”或点某一句进入单句循环。
   - 播放的是去掉主唱后的伴奏（保留和声），可以在 ⚙ 里调伴奏和原唱导唱的音量。
   - 中间的音高图随音乐滚动，竖线是当前位置；你的声音实时画成轨迹：
     **石绿**=准（默认 ±50 音分），**石青**=偏低，**朱砂**=偏高，接近时混入藤黄。唱过的字会按得分变色。
   - 顶部显示目标音、你的音和偏差（高/低多少音分）。
   - 点右上角的评分按钮或唱完整首，会看到总分、每句得分，以及“需要加强的字”
     （偏高 / 偏低 / 没唱出来 / 不稳 / 抢拍 / 进晚了）。点任意一句就进入该句的循环练习。
   - **单句循环、重唱这一句**只算这一句：播放会从这一句前面一秒多开始，这段前奏（以及循环时句尾后面的一小段）
     里出现的上一句、下一句的字不计分，也不会盖掉你之前唱的录音。每句的分数和录音一样，
     保留到你再唱这一句为止：循环某一句、拖动进度条，都不会清掉别的句子。
   - 查看评分或唱完后保存练习记录。**一次练习是一条记录**：中途看几次评分都只更新同一条；
     整首唱完再从头唱、改成循环某一句（或换一句循环），才算新的一次。唱了八成以上（按音符时长）
     才算一次整首练习，计入最高分和得分趋势；没唱完的和单句循环只记每一句的分数。
   - 切后台、锁屏、来电，或拔掉耳机、蓝牙断开时暂停播放和采集
     （免得突然从扬声器外放），返回后点播放继续；插上耳机、系统调整音频线路时继续播放。
     自由练习返回后点“继续练习”。练习、自由练习采集时和成品试听播放时屏幕保持常亮。
   - **听原唱**：歌词下面的“听这句原唱”（或评分页每句旁边的人像按钮）把这一句连同原唱人声放一遍，
     不计分、不录音；放完回到这一句开头暂停，点播放就可以跟着唱。
   - **回听**：评分页点“回听这一遍”，或点某一句旁边的耳机只听这一句。播放的是你刚才唱的
     （按延迟补偿放在你听到伴奏的位置）加伴奏，原唱静音，音高图显示你当时的音高线；
     回听时麦克风不计分。点“回到练习”继续练。录音只在内存里，点“制作成品”才会保存。
   - **制作成品**：评分页点“制作成品”，这一遍唱的会保存为这首歌的“我的录音”，并打开成品页：
     边听边调人声、伴奏、混响和人声对齐（±300 ms），选整首歌或只要唱了的部分、或者只要人声
     （只要人声配整首歌时，导出的人声和原曲一样长，在别的 App 里能直接和伴奏对齐），
     点“导出成品”。导出在后台合成和编码（AAC 256 kbps，m4a），保存在“文件”App 的
     我的 iPhone › YinTrace 里，并弹出系统分享面板（存到别处、隔空投送、发给朋友）。
     歌曲页的“我的录音”可以再次导出或删除。戴耳机录的成品最干净。
   - **得分趋势**：歌曲页显示最近 20 次整首练习的得分走势；每一句的分数旁有一条小折线，
     是这一句最近 10 次的得分（包括单句循环），练一句有没有进步一眼就能看到。
4. **自由练习**：曲库右上角的波形按钮，是一个实时音高监视器，
   显示音名、频率、简谱唱名、音分偏差和滚动的音高轨迹。

**建议戴耳机练习**：外放时麦克风会录到伴奏和导唱，音高检测会受干扰。
**延迟**：App 会读取系统报告的输入/输出延迟并自动补偿；如果你的轨迹总比参考线偏右（晚），
在设置里把“延迟补偿”调大（蓝牙延迟因设备和连接方式而异，需要实测）。

## 歌词格式

```
[00:12.40]夜里的风慢慢吹过窗台
[00:17.95]远处的灯一盏一盏亮开
[00:35.80]下雨了 记得带伞
```

- 每行 `[分:秒.百分秒]歌词`，时间是这一句**开始唱**的时刻（毫秒 `.123` 也可以）。
- 每个汉字（以及假名、韩文音节）是一个单位；英文按单词。标点会被忽略。
- 中文里**空格表示停顿**，对齐时会优先在空格处找换气点；英文单词之间的空格只是分词，
  标点（逗号、句号）才表示停顿。
- 语言自动识别（有假名就是日文，英文单词比汉字多就是英文），导入页会显示识别结果。
  英文按每个单词的音节数、日文按拍（假名）估计每个单位唱多长，再在音节起点上对齐。
- 日文：小假名、促音“っ”和长音“ー”跟前面的假名算一个单位（きょ、まっ、ラー）。
  汉字后面紧跟括号里的平假名会当作读音：`心(こころ)`、`明日（あした）`——这个汉字按读音的拍数和
  第一个假名来对齐，显示的仍是汉字。没写读音的汉字按平均约 2 拍估计。
- 也支持标准 LRC 的扩展：一行多个时间 `[00:12.00][01:30.00]副歌`、`[offset:+200]`、
  `[ti:歌名]` 等标签、只有时间没有歌词的行（表示上一句结束），以及逐字时间 `<00:12.30>字`
  （有逐字时间时会直接使用）。
- **带翻译的歌词**：播放器导出的双语歌词里，原文和译文是时间相同的两行。时间相同的几行里，
  写在最前面的一行是要唱的，后面的当作它的翻译：不对齐、不计分，在歌曲页和练习页显示在这一句下面。
  导入页会写明有几行被当作翻译。如果译文写在原文前面，请把两行对调。

## 工作原理

```
音频文件 ──► 解码 (Core Audio / miniaudio) ──► 44.1 kHz 立体声
   │
   ├─► MDX-Net Voc_FT：STFT(7680/1024) → [1,4,3072,128] → ONNX → iSTFT，
   │   分块 + Hann 重叠相加（UVR demix 的移植）                  ──► 人声
   │
   ├─► VR 6_HP-Karaoke：多频带 STFT + 重采样拼接 → 全曲最大值归一化 → 512 帧窗口
   │   （与 UVR 整曲处理同一网格，每个窗口推理一次）→ ONNX 掩码 → aggressiveness →
   │   (1-mask)·X → 分频带 iSTFT 合成                              ──► 主唱
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
  两种 karaoke 频带配置、两个 stem 的误差都在 2e-4 以内；VR 分段处理与整曲处理的差别在 1e-5 以内
  （测试用依赖整个窗口上下文的假模型，段长从 0.1 秒到 15 秒都验证过）。
  真实两个模型也按 App 的参数对照：14 秒合成混音上，MDX 信号/差值比 120.0 dB，
  VR 主唱 141.3 dB、被移除部分 118.2 dB，详见[验证记录](docs/inference-memory.md)。
- **速度与内存**：MDX 单块滚动累加，模型推理当前块时同时计算下一块的 STFT 和上一块的逆变换。
  VR 不能一次放下整首歌的频谱，所以约 15 秒一段计算，但窗口放在 UVR 整曲处理的同一网格上：
  每个窗口只推理一次，段边界只多算几帧上下文，结果与整曲处理在浮点误差内相同，不需要交叉淡化。
  VR 期间释放混音，结束后重新解码并复用为伴奏缓冲。两个模型顺序加载、关闭，CPU arena 关闭
  （Apple 插件为此带有本地补丁）。桌面独立推理峰值 MDX 约 508 MB、VR 约 1072 MB（512 窗口）。
  导入开始时读取 iOS 报告的剩余内存（`os_proc_available_memory`），不够 512 窗口用时自动改用 320
  （约 835 MB，但推理次数是 4 倍），小内存的旧 iPhone 也能完成。真机峰值仍须用 release + Instruments 验收。
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
    analysis/     LRC 解析、语言识别（中/英/日）、离线音高跟踪、逐字对齐、参考旋律与校正
    import/       导入流水线（后台 isolate）
    library/      本地曲库（每首歌一个目录）、练习记录、我的录音
    practice/     实时音高跟踪、评分、练习会话、校正页的片段播放
    export/       制作成品：混音、后台导出、保存录音
    models/       两个分离模型的下载、校验、动态时间轴配方与 .pth → ONNX 组装
    app/          设置、全局服务、第三方许可登记
    ui/           曲库 / 导入 / 歌曲 / 校正音高 / 练习 / 评分 / 制作成品 / 自由练习 / 设置 页面，音高图绘制
packages/flutter_onnxruntime/ 固定 1.9.0 的本地副本，补齐 Apple useArena（保留 MIT 许可）
packages/yintrace_audio/   原生音频核心（C + miniaudio，dart:ffi）
  src/yt_audio.c            解码、全双工练习引擎、采集环形缓冲（带歌曲帧号）
  src/yt_platform_apple.inc AVAudioSession（线路变化按原因区分）、麦克风权限、ExtAudioFile 解码、
                            AAC 编码、系统分享面板
tools/
  build_karaoke_graph.py    生成 assets/models 里的网络结构和拷贝配方，并与 PyTorch 对照验证
  fetch_models.sh           给测试和工具用：下载两个模型并校验
  reference/                生成测试参考数据的脚本（numpy / torch / librosa / UVR 原代码）
test/                       单元测试、对照测试、端到端 UI 测试
```

本地数据：

- 曲库在 App 的 Application Support 目录 `songs/<id>/`：`song.json`（信息与歌词）、
  `reference.json`（逐字音高图）、`pitch.bin`（音高曲线）、`vocals.m4a`（主唱）、
  `accompaniment.m4a`（伴奏）、`history.json`（练习记录）、
  `takes/`（我的录音：每段一个 m4a 和一个记录混音设置的 json）。
  以前的版本导入的歌还有一份 `original.*`（原文件的副本），现在不再保存，也没有地方用到它。
- 导出的成品在 App 的 Documents 目录，“文件”App 里显示为 我的 iPhone › YinTrace。
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

**真机测速**：测导入一首歌的实际耗时，并比较 CPU 与 Core ML 的速度、内存和结果差异。
只有手机时，装 CI 产出的测试版（设置里多一个“性能测试”），测完复制报告，见
[只用 iPhone 测试](docs/phone-testing.md)；有 Mac 时也可以运行 `tools/device_benchmark.sh <设备 ID>`，
生成 `build/device-benchmark.md`，见 [真机测速](docs/device-benchmark.md)。两者是同一份测速代码
（`lib/src/benchmark/`）。

`.github/workflows/ci.yml` 在 Linux 上跑以上测试，在 macOS 上做 **iOS 无签名归档**
（测试版，打包成未签名的 `YinTrace-test-unsigned.ipa` 作为构建产物，自己用 Apple ID 签名安装）、
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
- iPhone 实测（iPhone18,3，iOS 27.0.1，8 GB 内存，测试版的“性能测试”，4 分钟的合成歌曲，两个模型都用 CPU）：
  完整导入 236 秒，约等于歌曲时长（人声分离 95 秒，去和声 135 秒）。同一台 4 核桌面上同一段 259.6 秒的输入，
  完整导入用 273 秒，改动前用 722 秒（[验证记录](docs/inference-memory.md)）。手机上的耗时取决于机型；
  导入页按这台设备的实测速度显示预计剩余时间。
- 人声分离在 Apple 设备上默认用 Core ML（GPU）：在上面那台 iPhone 上每次运行 0.26 秒，CPU 4 线程是 0.76 秒，
  与 CPU 的差值比 109 dB（结果一致），内存和 CPU 差不多。每台设备第一次导入（以及 App 或系统更新后）先用一段和 CPU 对比；
  不一致、出错，或 App 在启动 Core ML 时被系统关闭，都会自动改回 CPU。用 Core ML 的完整导入还要再测一次。
- 去和声模型只用 CPU：在那台 iPhone 上它的每种 Core ML 设置都让 App 被系统关闭。它现在是导入里最慢的一步。
- 内存不足时自动改用的 320 窗口要多跑 4 倍的去和声模型，导入会明显变慢。
- 解码和 VR 输入/输出仍随曲长占内存，尚未做到整条流水线流式处理。
- 分离和去和声的质量取决于 UVR 模型本身；有残留伴奏的段落会被电平门限过滤，可能少测到个别字。
- 练习时外放会让麦克风录到伴奏，请尽量戴耳机；制作成品时，外放录下的伴奏也会混进人声里。
- 英文的音节数是按元音估的（`beautiful` 3、`love` 1），少数单词会差一个；日文汉字没写读音时只能按平均拍数估，
  对齐会比写了读音时差一些。逐字时间 `<mm:ss.xx>` 对各种语言都最准。
- 混响是一个简单的房间混响（Schroeder–Moorer 结构），不是专业的人声处理链：没有压缩、均衡和修音。
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
