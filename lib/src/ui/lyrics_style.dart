import 'package:flutter/painting.dart';

import '../analysis/lyrics_language.dart';

/// Style for lyric text. The app's text styles prefer Chinese fonts, which
/// draw kanji in their Chinese forms: Japanese lyrics get Japanese fonts and
/// the Japanese locale instead.
TextStyle? lyricsStyle(TextStyle? style, LyricsLanguage language) {
  if (style == null || language != LyricsLanguage.japanese) return style;
  return style.copyWith(
    locale: const Locale('ja', 'JP'),
    fontFamilyFallback: const ['Hiragino Sans', 'Hiragino Kaku Gothic ProN', 'Noto Sans CJK JP', 'PingFang SC'],
  );
}
