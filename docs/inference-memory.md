# 推理内存与验证记录

2026-11-14，Linux x86-64，Python ONNX Runtime 1.32.0，CPU provider，
`intra_op_num_threads=4`。每行独立进程，确定性 float32 输入，加载 session 后推理
三次，读取 `resource.getrusage().ru_maxrss`。下表使用十进制 MB，包含该 Python
进程的全部 RSS，**不包含 Flutter，也不是 iPhone 的 Physical Footprint**。

| 模型 / 配置 | 峰值 RSS (MB) |
|---|---:|
| 原 MDX，固定 T=256，arena 开 | 2662 |
| 动态 MDX，T=128，arena 开 | 610 |
| 动态 MDX，T=128，arena 关（当前默认） | 488 |
| 原 VR，固定 512，arena 开 | 1901 |
| 动态 VR，512，arena 开 | 1697 |
| 动态 VR，320，arena 开 | 1247 |
| 动态 VR，320，arena 关（当前默认） | 816 |

复现（先运行 fetch_models.sh 和两个配方工具；不要提交输出模型）：

```bash
export ORT_DISABLE_TELEMETRY=1
python tools/build_mdx_recipe.py build/uvr-models/UVR-MDX-NET-Voc_FT.onnx \
  --out-dir build/mdx-recipe --out build/uvr-models/UVR-MDX-NET-Voc_FT-dynamic.onnx
python tools/build_karaoke_graph.py verify build/uvr-models/6_HP-Karaoke-UVR.pth \
  --out build/uvr-models/6_HP-Karaoke-UVR-dynamic.onnx
python tools/benchmark_inference.py build/uvr-models/UVR-MDX-NET-Voc_FT-dynamic.onnx --shape 1 4 3072 128 --no-arena
python tools/benchmark_inference.py build/uvr-models/6_HP-Karaoke-UVR-dynamic.onnx --shape 1 2 641 320 --no-arena
```

ORT 1.29+ 的 API 禁用调用可能晚于初始化遥测，所以工具还在 import 前设置
`ORT_DISABLE_TELEMETRY=1`，CI 同样设置。App 的 Apple ORT 保持插件原先固定的
1.28.0；本地插件补丁仅让已有的 `useArena: false` 在 iOS/macOS 生效，未增加其他模型。
固定版本内部头文件的来源和升级要求见 `packages/flutter_onnxruntime/YINTRACE_CHANGES.md`。

## 参数、配方与代价

- MDX 输入和输出的第 4 维（从 0 起为轴 3）原编码均为 `08 80 02`；
  工具沿 protobuf 字段定位到字节偏移 66762437、66762483，换成等长 `12 01 54`。
  不搜索或修改权重；输出 SHA-256：
  `86532df82bb423e62e542e3e3856cba54b4235724177b4d21d77260b59cbd322`。
- 默认 MDX T=128、overlap=0.5。较短上下文会改变分离结果：交接时提供的 26 秒
  混音评估中，T=256 为 23.03 dB SDR，T=128 / overlap=0.5 为 22.36 dB。
  这些是交接测量，并未重新使用那份未提供的混音复测。选择 128 保留较多上下文，
  不能宣称与 256 的结果相同。
- VR 导出动态时间轴，只验证并使用 320 / 512 这两个可被 32 整除的窗口。
  当前默认 320，保留 offset=128，因此有效步长由 256 降为 64，推理次数约四倍；
  每次耗时和内存较小，但总耗时增加。网络权重、aggression 和前后处理不变。
  新 ONNX SHA-256：`6247a65bd0e23c18d8f98df3ad5b40c0f8d4acc0da6949bf61847c3dad50c26e`。
- 两个阶段依次加载和关闭 session。MDX 将两个声道累加及 divider 改为单块滚动缓冲，
  不再按整曲分配三份单声道数组；5 分钟时原约 159 MB 变为约 1.6 MB。
  VR 阶段不再保留原混音：关闭 VR session 后重新解码本地源文件，再原地减去主唱生成伴奏。
  VR 音频分段由 30 秒缩为 12 秒（仍有两侧 3 秒上下文），并原地应用掩码，避免复制复数频谱。
  这会多做一些上下文推理和一次解码，以换取较低内存；分析前丢弃不用的 stereo 引用。
  音频解码、VR 输入/输出仍与曲长有关；这还不是全流程流式解码。

## 数值与耗时

在同一份 14 秒合成混音上，以 UVR 自身代码和相同参数作参考：
Dart MDX 与 UVR 的信号/差值比为 117.7 dB；VR 主唱 126.5 dB、被移除部分 110.2 dB。
这验证移植与参数一致，不能用来证明对所有歌曲的主观音质。

这次桌面测试 MDX 共 12 次推理，17.2 秒（含前后处理）；VR 每遍 23 次，24.5 秒。
短片有额外 padding，测试也有并发负载，不能直接换算为整首歌或手机耗时。
导入页只显示阶段、进度与实际已用时间，移除了基于固定阶段权重推算的总剩余时间。

整进程 1.5 GB 目标仍需 iPhone release + Instruments 验收，步骤见
[ios-validation.md](ios-validation.md)。模拟器冒烟测试另设 1.5 GB 峰值回归门限，
但不替代长歌曲、真实设备和连续导入测试。


长音频宿主机采样工具（只在 Linux 上使用）：

```bash
MODELS_DIR=$PWD/build/uvr-models REAL_IMPORT_AUDIO=/path/to/audio.wav \
REAL_IMPORT_LYRICS=/path/to/lyrics.lrc PYTHON=python \
YINTRACE_AUDIO_LIB=$PWD/build/host/libyintrace_audio.so \
python tools/benchmark_import.py --out build/import-memory.json
```

工具以 10 Hz 同时采样 flutter_tester 与它的 ORT 子进程，排除 Flutter CLI / 编译器。
它补充独立进程的峰值测量，不能把两个不同时间的峰值相加当作实际同一时刻的峰值，
也不能将宿主机 RSS 直接等同 iPhone 的 Physical Footprint。


## 整曲压力测试

相同的 259.6 秒本地纯人声，经 MDX → VR → YIN → 对齐 → 保存完整链路运行；
此处用纯人声作为压力输入，不据此评价混音分离质量。音频、歌词和生成曲库未提交。
当前 12 秒 VR 分段、释放混音与频谱复用的结果：

| 项目 | 结果 |
|---|---:|
| 完整流水线耗时（不含测试启动） | 895 秒（14 分 55 秒） |
| 歌词单位 / 结构验证 | 315 / 通过 |
| Dart App 独立峰值 RSS | 562.6 MB |
| App 与 ORT 子进程同时采样峰值 RSS | 1380.2 MB |
| 该峰值时的 App / ORT RSS | 554.4 / 825.8 MB |
| 采样间隔 / 样本数 | 0.1 秒 / 8838 |

这包含调试模式 Dart VM 与 Python ORT 运行时，排除 Flutter CLI 和编译器；
进程间共享页可能重复计入，短于采样间隔的瞬态也可能遗漏。独立 max RSS 不等同于
同一时刻的总峰值。优化前同一长输入的 Dart 独立峰值为 780.5 MB，进一步缩小分段
并释放混音后降为 562.6 MB；该轮耗时从 758 秒增加到 895 秒。

宿主压力测试低于 1.5 GB，但 iPhone 的释放行为、ORT 版本、CPU 内核和系统预算不同，
仍须使用真机 release + Instruments 测量，不能据此保证所有 iPhone 不会被 jetsam 终止。


## iOS 模拟器实跑

[CI 运行 43554773740](https://github.com/zhikkz/YinTrace/actions/runs/43554773740)
验证代码提交 `4174195`。GitHub Actions macOS 15 ARM64 runner 上的 iPhone 16 Pro
模拟器，ONNX Runtime 1.28.0，CPU provider，4 个 intra-op 线程，CPU arena 关闭：

| 同一 App 进程中的阶段 | 3 次推理耗时 | 截至该阶段的进程峰值 RSS |
|---|---:|---:|
| MDX `[1,4,3072,128]` | 10.624 秒 | 786.2 MB |
| VR `[1,2,641,320]` | 12.215 秒 | 879.5 MB |

这里直接使用实际的 Flutter Apple 插件和 ORT 原生桥接，同一进程包含 Flutter 与 ORT，
不是把两个进程的独立峰值相加。AAC 编码/解码、官方模型下载/校验/组装、运行时读取
包含 AGPL v3 的 NOTICES.Z 也均通过；release 归档和全部 FFI 导出符号检查通过。
测试绑定有意禁用了 Flutter 自动许可登记，所以许可检查读取的是实际打包的资产，
并另查应用自行登记的 UVR 致谢；正常 App 的 ServicesBinding 从同一资产登记许可。

这是调试模式、短窗口推理的模拟器结果，不是整曲 iPhone release 的 Physical Footprint。
真实麦克风授权、耳机/电话中断、延迟、Files 和长曲连续导入仍需按设备清单验收。
