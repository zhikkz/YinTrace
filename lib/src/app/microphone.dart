import 'dart:io';

/// What to tell the singer when the microphone is not allowed: where to
/// allow it in the system settings.
String get microphoneDeniedMessage => Platform.isAndroid
    ? '没有麦克风权限：请在 系统设置 → 应用 → 音迹 → 权限 → 麦克风 中选择允许'
    : '没有麦克风权限：请在 系统设置 → 隐私与安全性 → 麦克风 中允许音迹';
