import 'package:flutter/foundation.dart';

/// Exports are written to the app's documents folder. The Files app shows
/// it on iOS. On Android it is the app's own storage, which file managers
/// and other apps cannot see: the share sheet is the only way out.
bool get _exportsStayPrivate => defaultTargetPlatform == TargetPlatform.android;

/// Under "已导出 …": where else the file can be found.
String get exportLocationHint => _exportsStayPrivate
    ? '文件存在音迹自己的存储里，文件管理器里找不到；要留一份，点“分享或存到别处”存到网盘或发给自己。'
    : '在「文件」App 的 我的 iPhone › 音迹里也能找到。';

/// What to say when the share sheet did not open. [saved] tells where the
/// file is, for platforms where the user can get to it.
String shareFailedNotice(String saved) => _exportsStayPrivate ? '没能打开分享面板，点“分享或存到别处”再试一次。' : saved;
