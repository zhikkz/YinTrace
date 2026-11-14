# 推理速度、内存与验证记录

## 当前设置

| 模型 | 设置 | 依据 |
|---|---|---|
| UVR-MDX-NET-Voc_FT | segment size 128（UVR 可选值，UVR 默认 256），重叠 0.25（UVR 默认） | 内存约为 256 的一半；每秒音频的计算量比 256 略少 |
| 6_HP-Karaoke-UVR | 窗口 512（UVR 默认），按 UVR 整曲的窗口网格分段 | 推理次数是 320 窗口的四分之一 |
| 6_HP-Karaoke-UVR（内存不足时） | 窗口 320 | 系统报告的剩余内存不够 512 时自动使用 |

两个模型都在 CPU 上运行，4 个 intra-op 线程，ONNX Runtime 的 CPU arena 关闭，
顺序加载、用完即关。

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
对照结果 117.7 dB 和 126.5 / 110.2 dB。这验证移植与参数一致，不能用来证明对所有歌曲的主观音质。

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
这是调试模式、短窗口推理的模拟器结果，不是整曲 iPhone release 的 Physical Footprint。真实麦克风授权、耳机/电话中断、延迟、Files 和长曲连续导入
仍需按设备清单验收。

ORT 1.29+ 的 API 禁用调用可能晚于初始化遥测，所以工具还在 import 前设置
`ORT_DISABLE_TELEMETRY=1`，CI 同样设置。App 的 Apple ORT 保持插件原先固定的
1.28.0；本地插件补丁仅让已有的 `useArena: false` 在 iOS/macOS 生效。
固定版本内部头文件的来源和升级要求见 `packages/flutter_onnxruntime/YINTRACE_CHANGES.md`。
