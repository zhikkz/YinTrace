# 模型相关的打包文件

App 只使用 Ultimate Vocal Remover 的两个模型，都在第一次需要时从 UVR 的官方模型库下载，
**权重文件不在这个仓库里，也不打包进 App**：

| 用途 | 下载的文件 | 大小 |
|---|---|---|
| 人声分离 | `UVR-MDX-NET-Voc_FT.onnx` | 67 MB |
| 去和声 | `6_HP-Karaoke-UVR.pth` | 127 MB |

这个目录里的两个文件是把 `6_HP-Karaoke-UVR.pth`（PyTorch 权重）变成手机上能跑的 ONNX
模型所需要的“配方”，由 `tools/build_karaoke_graph.py` 生成：

- `karaoke_graph.bin`：ONNX 文件里除权重以外的全部字节，也就是网络结构（约 130 KB）。
- `karaoke_graph.json`：拷贝配方。每一段是
  `[从 karaoke_graph.bin 取多少字节, 在 .pth 里的偏移, 从 .pth 拷多少字节]`，
  以及 `.pth` 和生成结果的 SHA-256。

`.pth` 是一个 zip，里面每个权重张量都是原样存放的小端浮点数，所以 App 下载并校验官方文件后，
按配方拷贝字节就能拼出 ONNX 模型，不需要 PyTorch，结果和在电脑上用 PyTorch 导出的逐字节相同。

`*.onnx`、`*.pth` 已被 `.gitignore` 排除。
