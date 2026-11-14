# 真机测速

测人声分离在 iPhone 上的速度和内存，回答两个问题：

1. **手机上现在有多快**：用 App 实际的导入流程（后台线程、CPU、和正式版相同的设置）完整导入一首
   合成歌曲，记录各阶段耗时、整体是歌曲时长的几倍、内存峰值，以及导入页“预计还需”的误差。
2. **CPU 和 Core ML 各有多快**：两个模型分别用 CPU（2 / 4 / 全部线程）运行，人声模型再用几种 Core ML 设置
   （MLProgram 或 NeuralNetwork 格式；CPU+GPU、全部计算单元、CPU+神经网络引擎）运行，
   比较加载时间（含 Core ML 编译）、每次推理时间、内存峰值，以及 Core ML 的结果和 CPU 差多少。

第一次在 iPhone 上测（iPhone18,3，结果见 [推理速度与内存](inference-memory.md#iphone-实测)）：
人声模型用 Core ML 的 GPU（MLProgram，CPU+GPU）比 CPU 快约 2.9 倍、结果一致，App 已经改用它
（每台设备第一次导入会再和 CPU 对比一次）；去和声模型的每种 Core ML 设置都让 App 被系统关闭，只用 CPU。
所以测速现在只比较人声模型的 Core ML 设置（App 用的那种排第一），去和声模型只测 CPU；完整导入按 App
当前的设置运行，报告里写明人声分离用的是 GPU 还是 CPU、和 CPU 的对比结果，以及两个模型在导入中每次的耗时。

有两种跑法，测速代码相同（`lib/src/benchmark/`），报告也相同：

- **只有手机**：装测试版（构建时加 `--dart-define=YINTRACE_BENCHMARK=true`，CI 产出的
  `YinTrace-test-unsigned.ipa` 就是），设置 → 测试版 → 性能测试，测完点“复制报告”。
  每测完一项都会保存，App 中途被系统关掉也能接着测，让 App 被关掉的设置会跳过并写进报告。
  步骤见 [只用 iPhone 测试](phone-testing.md)。
- **有 Mac**：`tools/device_benchmark.sh`，见下文。

报告先给出完整导入的结果，再给出 CPU 的各项，最后是 Core ML（最容易因内存被系统关掉的放在最后）。

## 用 Mac 跑

需要：Mac、Xcode、Flutter 3.47.9，iPhone 用数据线连接并已信任这台 Mac，
`ios/Runner` 已在 Xcode 的 Signing & Capabilities 里选好开发者团队（和平时 `flutter run` 一样）。

```bash
flutter pub get
cd ios && pod install && cd ..
tools/device_benchmark.sh                 # 列出设备，找到 iPhone 的设备 ID
tools/device_benchmark.sh <设备 ID>        # 60 秒的合成歌曲
tools/device_benchmark.sh <设备 ID> 240    # 想看一首 4 分钟的歌要多久
```

- 用 profile 构建，速度接近正式版。测试会替换手机上已装的 YinTrace（同一个 App），
  曲库和已下载的模型保留；第一次运行会下载两个 UVR 模型（194 MB）。
- 全程约 15 到 25 分钟（大部分时间花在 Core ML 编译模型上；240 秒的歌再多几分钟）。
  请保持手机亮屏、解锁、App 在前台，
  不要同时用手机做别的事，否则数字会偏慢。最好接着电源，手机发烫时会降频。
- 只用代码合成的音频和项目自己写的示例歌词，不读取曲库，不上传任何东西。

## 结果

终端里会打印每一项的进度和结果，结束后：

- `build/device-benchmark.md`：可读的报告（表格 + 结论），可以直接发给开发者；
- `build/integration_response_data.json`：原始数据。

报告里各列的意思：

| 列 | 含义 |
|---|---|
| 加载 | 创建推理会话的时间；Core ML 包括把模型编译成 Core ML 格式。每次导入要加载一次 |
| 第一次推理 | 包括一次性的准备工作 |
| 每次推理 | 之后几次的中位数；导入一首歌要跑 MDX 约 0.45 次/秒歌曲、VR 约 0.4 次/秒歌曲 |
| 相对 CPU 4 线程 | 大于 1 表示比 App 现在的设置快 |
| 与 CPU 差值比 | Core ML 的输出与 CPU 输出相比的信号/差值比，40 dB 以上分离结果实际上相同 |
| 内存峰值增量 | iOS 报告的 App 内存占用（Physical Footprint）在这一项里最多增加了多少 |
| 备注 | 出错信息；“发热”表示这一项结束时系统报告手机过热（serious 及以上），可能降了速 |

另外两行“建缓存 / 用缓存再加载”测的是 Core ML 编译结果能否缓存：如果用缓存后加载很快，
只有第一次导入需要等编译。

## 模拟器

`tools/device_benchmark.sh` 也能用模拟器的设备 ID 运行（自动改用 debug 构建），
但模拟器没有神经网络引擎，也不报告内存余量，只能说明测速代码能跑。
CI 每次在模拟器上跑一个快速版（`--dart-define=BENCH_QUICK=1`），检查 Core ML 选项能传到 ONNX Runtime。
