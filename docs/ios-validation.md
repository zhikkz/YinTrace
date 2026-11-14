# iOS 验收（需要 Mac 和 iPhone）

只有手机时，大部分项目可以用测试版完成，见 [只用 iPhone 测试](phone-testing.md)；
Instruments 的内存测量和查看 App 内部文件需要 Mac。

2026-11-14 的 [CI 实跑](https://github.com/zhikkz/YinTrace/actions/runs/43554773740) 已通过。
iPhone 16 Pro 模拟器中，实际 Flutter/ORT 同进程峰值约 879.5 MB（短窗口推理），
两个模型均连跑三次，AAC 往返、下载与组装及 AGPL 资产读取通过。

CI 归档证明可编译、所有 FFI 符号可见；模拟器冒烟测试覆盖真实 ONNX
推理、AAC 往返和运行中的 AGPL 资产。它们不能代替 iPhone 验收。
请使用 Flutter 3.47.9，iOS 16+，在真机以 release 运行，记录机型、iOS、
歌曲长度、两阶段耗时和 Instruments 的 Physical Footprint 峰值。

## 首次启动与练习

- [ ] 全新安装后第一次练习只出现一次麦克风授权；拒绝后有系统设置引导。
      自由练习也验证一次；在授权弹窗期间退出页面，不应留下设备或崩溃。
- [ ] 有线耳机、蓝牙耳机、外放分别测试伴奏、导唱和采集。
      默认模式 / 测量模式分别检查；确认 AVAudioSession 没有被设备初始化重置。
- [ ] 用节拍或回环录音测量实际输入/输出延迟，验证自动补偿和手动偏移方向，
      在切换耳机后确认延迟重新计算。
- [ ] 播放中切后台、锁屏、接电话：立即静音并停止采集，不再推进评分。
      回到前台仍暂停，点播放后从原位置继续；来电未结束时重试不应崩溃。
- [ ] 拔出耳机 / 插入耳机 / 断开蓝牙后暂停，不能突然由扬声器播放。
      点播放继续后音高、延迟、单句循环正常。自由练习也必须停止采集并可点继续。
- [ ] 快速退出练习、在音轨解码期间切后台和退出，确认不会再启用麦克风。
- [ ] 回听：戴耳机唱一遍，在评分页点“回听这一遍”和某一句的耳机。你的声音应与伴奏对齐
      （对不齐说明延迟补偿不准，调设置里的延迟补偿后再唱一遍比较），原唱静音；
      回听中途切后台、来电后不会恢复录音，点“回到练习”后计分正常。
- [ ] 整首练习几次后，歌曲页出现得分趋势；单句循环几次后，这一句旁边出现小折线。

## 导入与内存

- [ ] Files 中选择 mp3/m4a/wav，含 iCloud 文件；纯人声可跳过模型，并选择伴奏。
- [ ] 下载两个原版文件、断网续传、错误 SHA-256、从 Files 导入、删除和重新下载。
      旧版升级时 MDX 从已下载的官方文件生成补丁，旧 VR 需重新下载原始 .pth。
- [ ] 先测试一段短音频，再测试 5 分钟整曲；用 Instruments 的 Allocations / VM Tracker
      记录整个进程的 Physical Footprint（包含 Flutter、ORT、解码和音频缓冲），
      目标明显低于 1.5 GB。连续导入两次，检查 session 关闭后内存是否释放。
- [ ] 在测试版里运行 设置 → 性能测试（4 分钟，见 [只用 iPhone 测试](phone-testing.md)）并复制报告，
      或运行 `tools/device_benchmark.sh <设备 ID> 240`（见 [真机测速](device-benchmark.md)）：
      报告里有完整导入的各阶段耗时、内存峰值、去和声用的窗口、“预计还需”的误差，以及 CPU 与 Core ML 的对比。
- [ ] 分别记录 MDX / VR / 全流程耗时。README 的桌面结果不能用作 iPhone 承诺。
      导入页的“预计还需”在开始一分钟后应与实际剩余时间大致相符；记下偏差。
- [ ] 导入完成后看 `songs/<id>/song.json` 的 `modelInfo.vr`：写着 `(window 320)` 表示系统报告的
      剩余内存不够 512 窗口，自动用了更省内存但更慢的设置。分别在 4 GB 和 6 GB 以上的
      iPhone 上记录用了哪种窗口和 Instruments 峰值，据此校准
      `ImportPipeline.vrWindowFor` 的门限（目前按桌面测量估计）。
- [ ] 导入时取消和退出页面，确认曲库无半成品，模型可继续使用。
- [ ] 保存的 vocals.m4a / accompaniment.m4a 可播放，重新启动 App 后曲库仍可练习。
- [ ] 设置 → 致谢与开源许可中，能打开 `yintrace` 的完整 GNU AGPL v3，
      并看到 zhikkz 版权、源代码地址和新增的插件补丁声明。
- [ ] 浅色 / 深色启动页、桌面图标、练习 / 评分 / 关于页在真机显示正常。

Core ML 的用户开关已移除；发布路径只使用 CPU，避免把未验证的加速提供者交给用户。

## 系统内存上限

Apple 没有承诺“4 GB iPhone 的单 App 固定上限是 2 GB”。官方说明
内存限额会随 App 生命周期变化，也不直接等于设备物理内存。
使用 `os_proc_available_memory()` 查询当前剩余预算，仅作为即时参考；
用 Instruments / jetsam 报告判断实际风险。导入时 App 用它在 VR 的 512 和 320 窗口之间选择
（`NativeAudio.availableMemory`，模拟器上不报告，按 512 处理）。

`com.apple.developer.kernel.increased-memory-limit` 可供核心功能需要更多内存的
应用在**部分设备**上申请更高限额，但系统不保证提供额外内存，应用必须在没有
额外预算时仍能正确工作。本项目暂不添加该 entitlement，也不以它代替降内存。
真机确认确有需要时再评估开发者团队配置与支持机型。

官方资料：

- https://developer.apple.com/documentation/os/os_proc_available_memory
- https://developer.apple.com/documentation/bundleresources/entitlements/com.apple.developer.kernel.increased-memory-limit
- https://developer.apple.com/documentation/xcode/identifying-high-memory-use-with-jetsam-event-reports
