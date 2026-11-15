/// Parser for the timed lyrics the user types in, e.g.
///
/// ```
/// [00:12.40]夜里的风慢慢吹过窗台
/// [00:35.80]下雨了 记得带伞
/// ```
///
/// Also accepts several timestamps per line (`[00:12.00][01:30.00]text`),
/// `[offset:+120]` tags, metadata tags (`[ti:...]`) and enhanced LRC word
/// times (`<00:12.30>字`). Lines that share a time stamp with the line
/// before them are its translation (bilingual lyrics from a player), not
/// lines to sing.
library;

import 'lyrics_language.dart';

/// One unit that gets its own pitch segment: a CJK character, a kana (with
/// the small kana, sokuon or long vowel mark after it), a kanji word with
/// its reading, or a Latin word.
class LyricToken {
  const LyricToken(this.text, {this.spaceBefore = false, bool? pauseBefore, this.time, this.reading})
    : pauseBefore = pauseBefore ?? spaceBefore;

  final String text;

  /// Shown with a space before it: between words, and at a pause.
  final bool spaceBefore;

  /// The singer pauses before this token: punctuation, or a space between
  /// CJK characters. (A space between two words is not a pause.)
  final bool pauseBefore;

  /// Explicit start time from enhanced LRC (`<mm:ss.xx>`), if any.
  final double? time;

  /// Kana reading of a kanji token, from ruby in the lyrics: `心(こころ)`.
  final String? reading;

  LyricToken shifted(double offset) => LyricToken(
    text,
    spaceBefore: spaceBefore,
    pauseBefore: pauseBefore,
    time: time == null ? null : time! - offset,
    reading: reading,
  );

  @override
  String toString() => reading == null ? text : '$text($reading)';
}

class LyricLine {
  LyricLine({required this.start, required this.text, required this.tokens, this.end, this.translation});

  /// Start time in seconds.
  final double start;

  /// Start of the next line (null for the last line).
  double? end;
  final String text;
  final List<LyricToken> tokens;

  /// What the other lines with this line's time stamp say: shown under the
  /// line, not sung.
  String? translation;

  @override
  String toString() => '[${formatLrcTime(start)}]$text';
}

class LrcParseResult {
  LrcParseResult(this.lines, this.metadata, this.errors, {this.translations = 0});
  final List<LyricLine> lines;
  final Map<String, String> metadata;

  /// Human readable problems (line number, message).
  final List<String> errors;

  /// Lines taken as the translation of the line they share a time stamp
  /// with (see [LyricLine.translation]): not among [lines].
  final int translations;
}

final _timeTag = RegExp(r'\[(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?\]');
final _metaTag = RegExp(r'^\[([a-zA-Z]+):(.*)\]\s*$');
final _wordTag = RegExp(r'<(\d{1,3}):(\d{1,2})(?:[.:](\d{1,3}))?>');

double _toSeconds(String m, String s, String? frac) {
  var f = 0.0;
  if (frac != null && frac.isNotEmpty) {
    f = int.parse(frac) / (frac.length == 1 ? 10 : frac.length == 2 ? 100 : 1000);
  }
  return int.parse(m) * 60 + int.parse(s) + f;
}

String formatLrcTime(double seconds) {
  final cs = (seconds * 100).round();
  final m = cs ~/ 6000;
  final s = (cs % 6000) ~/ 100;
  final c = cs % 100;
  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}.${c.toString().padLeft(2, '0')}';
}

bool _isCjk(int r) =>
    isIdeograph(r) ||
    isKana(r) ||
    (r >= 0xAC00 && r <= 0xD7AF); // hangul syllables

bool _isWordChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    isLatinLetter(r) ||
    (r >= 0xFF10 && r <= 0xFF19) || // fullwidth digits
    (r >= 0xFF21 && r <= 0xFF3A) || // fullwidth letters
    (r >= 0xFF41 && r <= 0xFF5A) ||
    r == 0x27 || // apostrophe (don't)
    r == 0x2019;

bool _isSpace(int r) => r == 0x20 || r == 0x09 || r == 0x3000 || r == 0xA0;

bool _isHiraganaReading(String s) =>
    s.isNotEmpty && s.runes.every((r) => (r >= 0x3041 && r <= 0x309F) || r == 0x30FC);

class _TokenBuilder {
  _TokenBuilder(this.text, {required this.space, required this.pause, this.time, required this.word});
  String text;
  final bool space;
  final bool pause;
  final double? time;
  final bool word;
  String? reading;
  bool get ideographs => text.isNotEmpty && text.runes.every(isIdeograph);
  LyricToken build() => LyricToken(text, spaceBefore: space, pauseBefore: pause, time: time, reading: reading);
}

/// Splits a lyric line into tokens. Punctuation is dropped. Punctuation, and
/// a space next to a CJK character, mark a pause before the next token; a
/// space between two words only separates them.
///
/// Japanese: small kana, the sokuon and the long vowel mark join the kana
/// before them (きょう → きょ, う), and a hiragana reading in brackets right
/// after kanji (`心(こころ)`, `明日（あした）`) becomes that token's reading.
List<LyricToken> tokenize(String text) {
  final tokens = <_TokenBuilder>[];
  var pendingSpace = false, pendingPunct = false;
  final word = StringBuffer();
  double? pendingTime;
  double? wordTime;

  void add(String s, {required bool isWord, double? time}) {
    final prev = tokens.isEmpty ? null : tokens.last;
    final gap = pendingSpace || pendingPunct;
    final pause = prev != null && (pendingPunct || (pendingSpace && !(isWord && prev.word)));
    tokens.add(_TokenBuilder(s, space: prev != null && gap, pause: pause, time: time, word: isWord));
    pendingSpace = pendingPunct = false;
  }

  void flushWord() {
    if (word.isEmpty) return;
    add(word.toString(), isWord: true, time: wordTime);
    word.clear();
    wordTime = null;
  }

  var i = 0;
  while (i < text.length) {
    final m = _wordTag.matchAsPrefix(text, i);
    if (m != null) {
      flushWord();
      pendingTime = _toSeconds(m.group(1)!, m.group(2)!, m.group(3));
      i = m.end;
      continue;
    }
    final r = text.codeUnitAt(i);
    var rune = r;
    var len = 1;
    if (r >= 0xD800 && r <= 0xDBFF && i + 1 < text.length) {
      rune = 0x10000 + ((r - 0xD800) << 10) + (text.codeUnitAt(i + 1) - 0xDC00);
      len = 2;
    }
    final ch = text.substring(i, i + len);
    if (rune == 0x28 || rune == 0xFF08) {
      // Ruby right after kanji: 心(こころ).
      final close = text.indexOf(rune == 0x28 ? ')' : '）', i + 1);
      final prev = tokens.isEmpty ? null : tokens.last;
      if (close > i + 1 && word.isEmpty && !pendingSpace && !pendingPunct && prev != null && prev.ideographs &&
          prev.reading == null) {
        final reading = text.substring(i + 1, close);
        if (_isHiraganaReading(reading)) {
          // The reading covers the run of kanji just before it.
          while (tokens.length >= 2) {
            final a = tokens[tokens.length - 2], b = tokens.last;
            if (!a.ideographs || a.reading != null || b.space || b.pause) break;
            a.text += b.text;
            tokens.removeLast();
          }
          tokens.last.reading = reading;
          i = close + 1;
          continue;
        }
      }
    }
    if (_isCjk(rune)) {
      flushWord();
      final prev = tokens.isEmpty ? null : tokens.last;
      if (extendsPreviousKana(rune) && prev != null && !prev.word && !pendingSpace && !pendingPunct) {
        prev.text += ch; // きょ, かっ, そー
      } else {
        add(ch, isWord: false, time: pendingTime);
        pendingTime = null;
      }
    } else if (_isWordChar(rune)) {
      if (word.isEmpty) {
        wordTime = pendingTime;
        pendingTime = null;
      }
      word.write(ch);
    } else {
      flushWord();
      if (_isSpace(rune)) {
        pendingSpace = true;
      } else {
        pendingPunct = true;
      }
    }
    i += len;
  }
  flushWord();
  return [for (final t in tokens) t.build()];
}

/// Parses LRC text. Lines are sorted by time; empty lyric lines (used in
/// LRC files to mark the end of a phrase) close the previous line.
///
/// Of several lines with the same time stamp, the first one in the text is
/// the line to sing and the others are its translation: players export
/// bilingual lyrics this way, the original first. Two lines cannot be sung
/// at the same moment, and aligned as two lines the first would get no
/// pitch at all and the melody would go to the translation.
LrcParseResult parseLrc(String source) {
  final metadata = <String, String>{};
  final errors = <String>[];
  final entries = <(double, String)>[];
  final stops = <double>[];
  var offset = 0.0;
  final rawLines = source.replaceAll('\r\n', '\n').replaceAll('\r', '\n').split('\n');
  for (var n = 0; n < rawLines.length; n++) {
    final raw = rawLines[n].trim();
    if (raw.isEmpty) continue;
    final times = <double>[];
    var pos = 0;
    while (true) {
      final m = _timeTag.matchAsPrefix(raw, pos);
      if (m == null) break;
      times.add(_toSeconds(m.group(1)!, m.group(2)!, m.group(3)));
      pos = m.end;
    }
    if (times.isEmpty) {
      final meta = _metaTag.firstMatch(raw);
      if (meta != null) {
        final key = meta.group(1)!.toLowerCase();
        final value = meta.group(2)!.trim();
        metadata[key] = value;
        if (key == 'offset') {
          final ms = double.tryParse(value.replaceAll('+', ''));
          if (ms != null) offset = ms / 1000.0;
        }
      } else {
        errors.add('第 ${n + 1} 行缺少时间标签：$raw');
      }
      continue;
    }
    final text = raw.substring(pos).trim();
    for (final t in times) {
      if (text.isEmpty) {
        stops.add(t);
      } else {
        entries.add((t, text));
      }
    }
  }
  // By time; lines with the same time stay in the order they were written
  // (List.sort alone does not promise that).
  final order = List.generate(entries.length, (i) => i)
    ..sort((a, b) {
      final byTime = entries[a].$1.compareTo(entries[b].$1);
      return byTime != 0 ? byTime : a.compareTo(b);
    });
  stops.sort();
  final lines = <LyricLine>[];
  var translations = 0;
  double? lastTime;
  for (final i in order) {
    final (time, text) = entries[i];
    final tokens = tokenize(text);
    if (tokens.isEmpty) {
      errors.add('歌词“$text”中没有可识别的字');
      continue;
    }
    if (lastTime != null && (time - lastTime).abs() < 0.0005) {
      final line = lines.last;
      line.translation = line.translation == null ? text : '${line.translation} / $text';
      translations++;
      continue;
    }
    lastTime = time;
    // LRC offset: positive values make lyrics appear earlier.
    final start = (time - offset).clamp(0.0, double.infinity).toDouble();
    final shifted = [for (final t in tokens) t.shifted(offset)];
    lines.add(LyricLine(start: start, text: text, tokens: shifted));
  }
  for (var i = 0; i < lines.length; i++) {
    final nextStart = i + 1 < lines.length ? lines[i + 1].start : null;
    double? end = nextStart;
    for (final s in stops) {
      final st = s - offset;
      if (st > lines[i].start && (end == null || st < end)) {
        end = st;
        break;
      }
    }
    lines[i].end = end;
  }
  return LrcParseResult(lines, metadata, errors, translations: translations);
}
