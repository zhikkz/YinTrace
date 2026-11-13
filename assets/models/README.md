# 打包进 App 的模型（可选）

把准备好的模型文件放到这个目录后重新构建，App 首次启动时会把它们复制到
`Documents/models`：

- `UVR-MDX-NET-Voc_FT.onnx` + `UVR-MDX-NET-Voc_FT.json`
- `6_HP-Karaoke-UVR.onnx` + `6_HP-Karaoke-UVR.json`

用 `python tools/prepare_models.py ...` 生成这些文件（见仓库根目录 README）。
模型文件很大，已被 `.gitignore` 排除，不会提交到仓库。

也可以不打包：在 App 的“设置 → 导入模型文件”里导入，或用“文件”App / 访达
把它们拷到 YinTrace 的 `models` 文件夹。
