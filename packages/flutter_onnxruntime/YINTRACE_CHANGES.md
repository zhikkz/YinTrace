# YinTrace 的本地补丁

来源：pub.dev flutter_onnxruntime 1.9.0（MIT，MASIC AI）；保留原 LICENSE。
保留所有平台源码，避免破坏可移植性。上游说明见 README.md。

仅新增 iOS/macOS SessionOptionsHelper，用固定 ORT 1.28.0 的内部接口
CXXAPIOrtSessionOptions 调用 DisableCpuMemArena，让已有 Dart useArena 参数生效。
内部声明 ort_session_internal.h 来自 microsoft/onnxruntime v1.28.0（MIT）。
与上游已有的 Float16/Bool helper 一样，升级 ORT 时必须复核内部头文件。
新增 YinTrace 代码适用根目录 AGPL-3.0-only；第三方原始代码保留 MIT。

验证：CI iOS release 归档编译此桥接；真机 Instruments 验证峰值，见 docs/ios-validation.md。
