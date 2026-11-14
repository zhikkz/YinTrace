# 推理速度、内存与验证记录

## 当前设置

| 模型 | 设置 | 依据 |
|---|---|---|
| UVR-MDX-NET-Voc_FT | segment size 128（UVR 可选值，UVR 默认 256），重叠 0.25（UVR 默认） | 内存约为 256 的一半；每秒音频的计算量比 256 略少 |
| 6_HP-Karaoke-UVR | 窗口 512（UVR 默认），按 UVR 整曲的窗口网格分段 | 推理次数是 320 窗口的四分之一 |
| 6_HP-Karaoke-UVR（内存不足时） | 窗口 320 | 系统报告的剩余内存不够 512 时自动使用 |
| UVR-MDX-NET-Voc_FT 在 Apple 设备上 | Core ML：MLProgram 格式，CPU+GPU，编译结果缓存 | iPhone 上每次 0.26 秒，CPU 0.76 秒，差值比 109 dB（见下文 iPhone 实测） |

去和声模型（以及其它平台上的人声模型）在 CPU 上运行，4 个 intra-op 线程（iPhone 上 2 个和 6 个都更慢），
ONNX Runtime 的 CPU arena 关闭，顺序加载、用完即关。

人声模型的 Core ML 在每台设备第一次导入（以及 App 或系统更新后）时，用第一段有声音的内容和 CPU 的结果对比，
差值比低于 40 dB、算出无效数值或出错，就用 CPU 做完这首歌并在这台设备上停用 Core ML；创建 Core ML 会话
到第一段结果返回之间留一个标记文件，下次导入前还在，说明 App 在那里被系统关闭，同样停用。设置里可以关掉或重新打开
（`lib/src/import/vocal_acceleration.dart`）。

### MDX：重叠 0.25

交接时用一段 26 秒混音测过分离人声对真值的 SDR：T=256 为 23.03 dB，
T=128 / 重叠 0.25 为 22.22 dB，T=128 / 重叠 0.5 为 22.36 dB（那份混音没有提供，未复测）。
重叠 0.5 需要 1.5 倍的模型运行次数，只换来约 0.1 dB，所以回到 UVR 默认的 0.25。

MDX 输入和输出的第 4 维（从 0 起为轴 3）原编码均为 `08 80 02`；
`tools/build_mdx_recipe.py` 沿 protobuf 字段定位到字节偏移 66762437、66762483，
换成等长的 `12 01 54`（动态维度 `T`）。不搜索或修改权重；输出 SHA-256：
`86532df82bb423e62e542e3e3856cba54b4235724177b4d21d77260b59cbd322`。

模型推理一块时，Dart 同时计算下一块的 STFT 和上一块的逆 STFT（两块输入缓冲交替使用），
CPU 上的前后处理不再和推理排队。

### VR：整曲窗口网格上的分段

UVR 对整首歌算一个频谱，除以全曲最大幅度，再按 `窗口 - 2 × 128` 帧的步长切窗口推理。
手机放不下整首歌的频谱，所以 App 约 15 秒一段计算，但窗口放在 UVR 整曲的同一网格上：

- 分段从帧边界开始。三个频带的帧步长折算到 44.1 kHz 都是 432 个采样，
  所以每个频带的重采样和 STFT 都与整曲计算对齐；
- 每个窗口只推理一次，跨段的窗口留给下一段复用；
- 段边界只多算几帧（STFT 填充和逆变换影响的范围再加余量），算完丢掉；
- 第一遍按段求全曲最大幅度（只计各段自己的帧），和 UVR 的归一化相同。

结果与整曲处理在浮点误差内相同，不再需要交叉淡化。测试用一个输出依赖整个窗口内容和
窗口内位置的假模型，在 0.1 秒到 15 秒的段长下与整曲结果的差别都小于 1e-5，
并检查推理次数等于 UVR 的窗口数。改动前每 12 秒一段、两侧各多算 3 秒，段内的网格与
整曲不对齐，只能靠交叉淡化拼接；再加上 320 窗口，259.6 秒的音频要约 620 次推理，现在是 104 次。

VR 导出动态时间轴，验证过 320 / 512 两个窗口。ONNX SHA-256：
`6247a65bd0e23c18d8f98df3ad5b40c0f8d4acc0da6949bf61847c3dad50c26e`。

### 按剩余内存选择 VR 窗口

导入开始时读取 iOS 报告的剩余内存（`os_proc_available_memory`）。
512 窗口需要约 1.05 GB 给 ONNX Runtime，加上分离结果（每分钟立体声约 21 MB）
和 0.3 GB 余量；不够时用 320（模型运行次数是 4 倍，内存少约 240 MB）。
模拟器和其它平台不报告剩余内存，按 512 处理。门限按桌面测量估计，需用真机校准，
见 [ios-validation.md](ios-validation.md)。

## 单个模型的内存

2026-11-14，Linux x86-64，4 核，Python ONNX Runtime 1.32.0，CPU provider，
`intra_op_num_threads=4`。每行独立进程，确定性 float32 输入，加载 session 后推理
三次，读取 `resource.getrusage().ru_maxrss`。十进制 MB，包含该 Python 进程的全部 RSS，
**不包含 Flutter，也不是 iPhone 的 Physical Footprint**。

| 模型 / 配置 | 峰值 RSS (MB) | 每次推理 |
|---|---:|---:|
| 原 MDX，固定 T=256，arena 开 | 2662 | |
| 动态 MDX，T=256，arena 关 | 837 | 1.85 秒 |
| 动态 MDX，T=128，arena 关（当前） | 508 | 0.95 秒 |
| 原 VR，固定 512，arena 开 | 1901 | |
| 动态 VR，512，arena 关（当前） | 1072 | 1.1 秒 |
| 动态 VR，320，arena 关（内存不足时） | 835 | 0.72 秒 |

关闭 memory pattern、关闭权重预打包都只差十几 MB，不值得为此变慢。

复现（先运行 fetch_models.sh 和两个配方工具；不要提交输出模型）：

```bash
export ORT_DISABLE_TELEMETRY=1
python tools/build_mdx_recipe.py build/uvr-models/UVR-MDX-NET-Voc_FT.onnx \
  --out-dir build/mdx-recipe --out build/uvr-models/UVR-MDX-NET-Voc_FT-dynamic.onnx
python tools/build_karaoke_graph.py verify build/uvr-models/6_HP-Karaoke-UVR.pth \
  --out build/uvr-models/6_HP-Karaoke-UVR-dynamic.onnx
python tools/benchmark_inference.py build/uvr-models/UVR-MDX-NET-Voc_FT-dynamic.onnx --shape 1 4 3072 128 --no-arena
python tools/benchmark_inference.py build/uvr-models/6_HP-Karaoke-UVR-dynamic.onnx --shape 1 2 641 512 --no-arena
```

## 与 UVR 对照

14 秒合成混音，以 UVR 自身代码和相同参数作参考（CI 的 real-models 任务）：

| | 模型运行次数 | 与 UVR 的信号/差值比 |
|---|---:|---|
| MDX，T=128，重叠 0.25 | 8 | 120.0 dB |
| VR，窗口 512 | 6 | 主唱 141.3 dB，被移除部分 118.2 dB |

改动前（重叠 0.5、窗口 320、交叉淡化分段）同一片段为 12 次和 23 次，
对照结果 117.7 dB 和 126.5 / 110.2 dB。

14 秒只有一个 VR 分段，所以又在本地把这段合成音频拼接成 259.6 秒，用 UVR 自己的代码整曲处理
（不分段）作参考，App 的 Dart 代码跨 18 段处理：

| | 模型运行次数 | 与 UVR 整曲结果的信号/差值比 |
|---|---:|---|
| MDX | 119 | 117.2 dB |
| VR，窗口 512 | 104 | 主唱 132.1 dB，被移除部分 111.9 dB |

同一输入的完整导入（歌词按片段的音节写）也通过：音高曲线与 UVR 主唱用同一 YIN 分析的结果
在有声/无声和音高上的一致率都超过 98%。音频和歌词只在本地使用，未提交。
这验证移植与参数一致，不能用来证明对所有歌曲的主观音质。

## 整曲耗时

同一台 4 核 x86 Linux，同一段 259.6 秒的输入（合成片段拼接），用 `tools/benchmark_import.py`
跑完整 ImportPipeline（MDX → VR → 音高 → 对齐 → 保存）。Dart 是 `flutter test` 的调试模式，
模型在一个 Python 子进程里运行，张量经管道传递；所以这不是手机上的速度，只用来比较前后。

| | 交接时（494297e） | 现在 |
|---|---:|---:|
| MDX 运行次数 | 178 | 118 |
| VR 运行次数 | 约 620 | 104 |
| 完整流水线 | 722 秒 | 273 秒 |
| App 与 ORT 子进程同时采样的峰值 RSS | 1457 MB（599 + 859） | 1539 MB（474 + 1065） |

同一输入快 2.6 倍。VR 的 512 窗口让 ORT 多用约 200 MB，Dart 侧少用约 120 MB
（不再需要交叉淡化的权重缓冲，分段更紧凑）。峰值是两个进程 RSS 之和；Linux 上 Python 进程
关闭 session 后 RSS 不会回落，所以两者在流水线末尾相加，比实际同一时刻的占用偏高；
iPhone 上 ORT 在 App 进程内，关闭 session 即释放。真机仍须用 release + Instruments 测量。

## iPhone 实测

2026-11-14，iPhone18,3（iOS 27.0.1，6 核，8 GB），测试版的“性能测试”（release 构建）；开始时系统允许
App 再用 3440 MB。完整导入走 App 自己的后台导入流程，4 分钟的合成歌曲，两个模型都用 CPU：

| 项目 | 结果 |
|---|---|
| 总耗时 | 236.2 秒（0.98 倍歌曲时长） |
| 分离人声 | 94.9 秒（110 次，每次约 0.86 秒，含张量传递和 STFT） |
| 去和声（窗口 512） | 135.1 秒（96 次，每次约 1.4 秒） |
| 测音高 / 对齐 / 保存 | 4.0 / 0.9 / 1.2 秒 |
| 内存峰值增量 | 1856 MB |
| “预计还需”的误差（25% / 50% / 75% 处） | +44 / −3 / −5 秒 |

单个模型，每次推理的中位数（秒），括号里是与 CPU 的差值比：

| 模型 | CPU 4 线程 | CPU 2 线程 | CPU 6 线程 | Core ML MLProgram CPU+GPU | MLProgram 全部单元 | MLProgram CPU+神经网络引擎 | NeuralNetwork 全部单元 |
|---|---:|---:|---:|---:|---:|---:|---:|
| MDX T=128 | 0.755 | 0.943 | 0.816 | 0.260（109.0 dB） | 0.257（109.0 dB） | 0.983（103.8 dB） | 0.588（44.2 dB） |
| VR 512 | 1.187 | 1.499 | 1.231 | App 被系统关闭 | App 被系统关闭 | App 被系统关闭 | App 被系统关闭 |
| VR 320 | 0.766 | 0.855 | 0.799 | 未测 | 未测 | 未测 | 未测 |

- MDX 在 GPU 上快约 2.9 倍，结果与 CPU 一致；神经网络引擎反而比 CPU 慢，NeuralNetwork 格式的差值比只有 44 dB、
  内存峰值增量 1.6 GB。所以 App 用 MLProgram + CPU+GPU。Core ML 的几项是在系统报告发热（serious）时测的，
  可能偏慢。
- 把时间轴固定回 128 的 MDX 并不更快（0.276 秒）。Core ML 编译缓存让加载从 0.8 秒降到 0.2 秒，
  第一次推理从 2.4 秒降到 0.5 秒，App 现在保留这个缓存。
- VR 的四种 Core ML 设置和缓存测试各让 App 被系统关闭一次（报告分不出是内存不够还是崩溃），所以 VR 只用 CPU，
  测速里也不再测它们。
- 导入的前 1/4（还在分离人声）“预计还需”短了 44 秒：在这台 iPhone 上一次 VR 相当于 1.6 次 MDX，之前按桌面和
  模拟器估的是 1.1。现在各阶段按这台 iPhone 的实测秒数加权，每次导入后记下这台设备自己的每次耗时，下次估算用
  （`ImportPipeline.defaultRunSeconds`）。
- 各项的内存峰值增量受测量顺序影响（第一个测的 MDX CPU 4 线程是 781 MB，之后的 CPU 2 / 6 线程约 300 MB），
  只能粗看。导入的峰值增量 1856 MB，4 GB 和 6 GB 的 iPhone 还没测，VR 512 / 320 的内存门限仍按桌面估计。

人声分离改用 Core ML 后，按上面的每次耗时估算，这首 4 分钟的歌分离人声约 40 秒、整个导入约 3 分钟，
需要下一次测速确认。

## iOS 模拟器

[CI 运行 43554773740](https://github.com/zhikkz/YinTrace/actions/runs/43554773740)
（改动前）：GitHub Actions macOS 15 ARM64 runner 上的 iPhone 16 Pro 模拟器，
ONNX Runtime 1.28.0，CPU provider，4 个 intra-op 线程，CPU arena 关闭：

| 同一 App 进程中的阶段 | 3 次推理耗时 | 截至该阶段的进程峰值 RSS |
|---|---:|---:|
| MDX `[1,4,3072,128]` | 10.624 秒 | 786.2 MB |
| VR `[1,2,641,320]` | 12.215 秒 | 879.5 MB |

[CI 运行 43573640909](https://github.com/zhikkz/YinTrace/actions/runs/43573640909)
（提交 `ee7e8d2`，同样的模拟器和 ORT，这台虚拟机整体慢约一倍，只看相对关系）：

| 同一 App 进程中的阶段 | 3 次推理耗时 | 截至该阶段的进程峰值 RSS |
|---|---:|---:|
| MDX `[1,4,3072,128]` | 22.5 秒 | 777 MB |
| VR `[1,2,641,320]` | 21.2 秒 | 837 MB |
| VR `[1,2,641,512]` | 23.1 秒 | 986 MB |

在 ARM 上 512 窗口每次只比 320 慢约 9%（x86 上约 1.5 倍），却覆盖 4 倍的帧，
所以去和声阶段快约 3.7 倍；进程峰值多约 150 MB。模拟器不报告剩余内存，App 按 512 处理。

[CI 运行 43583539156](https://github.com/zhikkz/YinTrace/actions/runs/43583539156) 在模拟器上
跑了一遍真机测速（`tools/device_benchmark.sh` 的流程，3 核虚拟机）：Core ML 的选项能传到 ONNX Runtime，
MLProgram 格式下 MDX 每次 2.0 秒，比 CPU 4 线程的 4.8 秒快约 2.4 倍，与 CPU 输出的差值比 100.8 dB；
VR 512 用 Core ML 反而更慢（7.8 秒对 4.7 秒）。3 核虚拟机上 2~3 个线程比 4 个快。
模拟器没有神经网络引擎，这些只说明代码路径可用，真机结果以 iPhone 上的测速为准。
这是调试模式、短窗口推理的模拟器结果，不是整曲 iPhone release 的 Physical Footprint。真实麦克风授权、耳机/电话中断、延迟、Files 和长曲连续导入
仍需按设备清单验收。

ORT 1.29+ 的 API 禁用调用可能晚于初始化遥测，所以工具还在 import 前设置
`ORT_DISABLE_TELEMETRY=1`，CI 同样设置。App 的 Apple ORT 保持插件原先固定的
1.28.0；本地插件补丁仅让已有的 `useArena: false` 在 iOS/macOS 生效。
固定版本内部头文件的来源和升级要求见 `packages/flutter_onnxruntime/YINTRACE_CHANGES.md`。
