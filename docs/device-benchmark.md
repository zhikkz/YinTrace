# 真机测速

`tools/device_benchmark.sh` 在连着的 iPhone 上测人声分离的速度和内存，回答两个问题：

1. **手机上现在有多快**：用 App 实际的导入流程（后台线程、CPU、和正式版相同的设置）完整导入一首
   合成歌曲，记录各阶段耗时、整体是歌曲时长的几倍、内存峰值，以及导入页“预计还需”的误差。
2. **Core ML 能不能更快**：两个模型分别用 CPU（2 / 4 / 全部线程）和几种 Core ML 设置
   （MLProgram 或 NeuralNetwork 格式；全部计算单元、CPU+神经网络引擎、CPU+GPU）运行，
   比较加载时间（含 Core ML 编译）、每次推理时间、内存峰值，以及 Core ML 的结果和 CPU 差多少。
   MDX 还额外测一个把时间轴固定回 128 的版本（Core ML 对固定形状通常更快）。

App 目前只用 CPU。测出 Core ML 明显更快、且结果和 CPU 足够接近（差值比 40 dB 以上）之后，
再把它接到导入流程里。

## 怎么跑

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
- 全程约 10 分钟（240 秒的歌再多几分钟）。请保持手机亮屏、解锁、App 在前台，
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

另外两行“建缓存 / 用缓存再加载”测的是 Core ML 编译结果能否缓存：如果用缓存后加载很快，
只有第一次导入需要等编译。

## 模拟器

`tools/device_benchmark.sh` 也能用模拟器的设备 ID 运行（自动改用 debug 构建），
但模拟器没有神经网络引擎，也不报告内存余量，只能说明测速代码能跑。
CI 每次在模拟器上跑一个快速版（`--dart-define=BENCH_QUICK=1`），检查 Core ML 选项能传到 ONNX Runtime。
