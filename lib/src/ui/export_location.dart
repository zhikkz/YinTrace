import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart' show SaveCopyResult;

/// Android: exports are written where file managers and other apps cannot
/// see them (see `exportDirectory`), so the page offers "存到手机" next to the
/// share sheet and deletes its file when it closes. iOS keeps them in the
/// folder the Files app shows.
bool get exportsAreTransient => defaultTargetPlatform == TargetPlatform.android;

/// Under "已导出 …": where else the file can be found.
String get exportLocationHint => exportsAreTransient
    ? '离开这里后音迹会删掉这个文件；要留一份，点“存到手机”或“分享或存到别处”。'
    : '在「文件」App 的 我的 iPhone › 音迹里也能找到。';

/// What to say when the share sheet did not open. [saved] tells where the
/// file is, for platforms where the user can get to it.
String shareFailedNotice(String saved) =>
    exportsAreTransient ? '没能打开分享面板；可以点“存到手机”，或者再点一次“分享或存到别处”。' : saved;

/// What to say after "存到手机"; null when the dialog was closed without saving.
String? saveCopyNotice(SaveCopyResult result) => switch (result) {
  SaveCopyResult.saved => '已保存到你选的位置。',
  SaveCopyResult.failed => '没能保存，请再试一次。',
  SaveCopyResult.cancelled => null,
};

/// Deletes exports the page wrote, where [exportsAreTransient].
void discardExports(List<String> paths) {
  if (exportsAreTransient) {
    for (final path in paths) {
      try {
        File(path).deleteSync();
      } catch (_) {}
    }
  }
  paths.clear();
}
