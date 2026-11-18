# 模型相关的打包文件

## 音高模型 `swift_f0.onnx`（随 App 附带）

测音高用的是 [SwiftF0](https://github.com/lars76/swift-f0)（Lars Nieradzik，MIT 许可）：一个只有 14 386 个参数的卷积网络，
从 16 kHz 音频的频谱里读出每 16 ms 一帧的音高和“这一帧有人声、音高可信”的置信度。App 在导入时用它测原唱的音高
（练习时测你唱的仍用 YIN）。它很小（135 KB），每次导入都要用，包括不需要下载分离模型的纯人声导入，
所以和 App 一起打包，不需要下载；这是仓库里唯一的模型文件（`.gitignore` 里单独放行）。

`swift_f0.onnx` 由 `tools/build_pitch_model.py` 从 PyPI 上 swift-f0 0.3.0 的官方 wheel 生成（wheel 和其中 `model.onnx`
的 SHA-256 都写在脚本里）。权重和网络一个字节不改，只改接口，让 App 的 ONNX Runtime 插件能直接运行：

- 输入 `fmin`、`fmax` 改成常量：在 60–1400 Hz 里找音高（最好的音高落在范围外的帧算没有人声）；
- 输出 `pitch` 从 float64 转成 float32（Apple 上的插件不支持 float64 张量），误差小于万分之一音分；
- `pitch` 和 `confidence` 合成一个输出 `pitch_confidence`，形状 `[2, 帧数]`。

```bash
python tools/build_pitch_model.py build    # 下载官方 wheel，校验，生成 assets/models/swift_f0.onnx
python tools/build_pitch_model.py verify   # 检查仓库里的文件就是脚本生成的，并且和原模型算出同样的音高和置信度
```

换模型版本时，重新生成后把 `lib/src/models/pitch_model.dart` 里的 SHA-256 和大小一起改掉（有测试核对）。

## 分离模型（第一次需要时下载）

App 只使用 Ultimate Vocal Remover 的两个分离模型，都在第一次需要时下载原版文件（hf-mirror.com 上的副本，不行时改用 UVR 的官方模型库），
**权重文件不在这个仓库里，也不打包进 App**：

| 用途 | 下载的文件 | 大小 |
|---|---|---|
| 人声分离 | `UVR-MDX-NET-Voc_FT.onnx` | 67 MB |
| 去和声 | `6_HP-Karaoke-UVR.pth` | 127 MB |

这个目录里的 `karaoke_graph.bin/.json` 是把 `6_HP-Karaoke-UVR.pth`（PyTorch 权重）变成手机上能跑的 ONNX
模型所需要的“配方”，由 `tools/build_karaoke_graph.py` 生成：

- `karaoke_graph.bin`：ONNX 文件里除权重以外的全部字节，也就是网络结构（约 136 KB）。
- `karaoke_graph.json`：拷贝配方。每一段是
  `[从 karaoke_graph.bin 取多少字节, 在 .pth 里的偏移, 从 .pth 拷多少字节]`，
  以及 `.pth` 和生成结果的 SHA-256。

`.pth` 是一个 zip，里面每个权重张量都是原样存放的小端浮点数，所以 App 下载并校验官方文件后，
按配方拷贝字节就能拼出 ONNX 模型，不需要 PyTorch，结果和在电脑上用 PyTorch 导出的逐字节相同。

`*.onnx`、`*.pth` 已被 `.gitignore` 排除（上面的 `swift_f0.onnx` 除外）。

`mdx_graph.bin/.json` 是 MDX 动态时间轴补丁的配方，仅有 6 个字面字节。
由 `tools/build_mdx_recipe.py` 沿 protobuf 输入/输出字段计算偏移生成，不含权重。
安装后名称为 `UVR-MDX-NET-Voc_FT-dynamic.onnx` 和 `6_HP-Karaoke-UVR-dynamic.onnx`，
独立命名避免误用旧的固定窗口文件。VR 从同一个官方 .pth 复制权重，图验证了 320 / 512 帧窗口。
完整哈希与内存测量见 `docs/inference-memory.md`。
