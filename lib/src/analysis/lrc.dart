/// Parser for the timed lyrics the user types in, e.g.
///
/// ```
/// [00:12.40]夜里的风慢慢吹过窗台
/// [00:35.80]下雨了 记得带伞
/// ```
///
/// Also accepts several timestamps per line (`[00:12.00][01:30.00]text`),
/// `[offset:+120]` tags, metadata tags (`[ti:...]`) and enhanced LRC word
/// times (`<00:12.30>字`).
library;

/// One unit that gets its own pitch segment: a CJK character, a kana, or a
/// Latin word.
class LyricToken {
  const LyricToken(this.text, {this.spaceBefore = false, this.time});

  final String text;

  /// The lyrics had a space (a pause) before this token.
  final bool spaceBefore;

  /// Explicit start time from enhanced LRC (`<mm:ss.xx>`), if any.
  final double? time;

  @override
  String toString() => text;
}

class LyricLine {
  LyricLine({required this.start, required this.text, required this.tokens, this.end});

  /// Start time in seconds.
  final double start;

  /// Start of the next line (null for the last line).
  double? end;
  final String text;
  final List<LyricToken> tokens;

  @override
  String toString() => '[${formatLrcTime(start)}]$text';
}

class LrcParseResult {
  LrcParseResult(this.lines, this.metadata, this.errors);
  final List<LyricLine> lines;
  final Map<String, String> metadata;

  /// Human readable problems (line number, message).
  final List<String> errors;
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
    (r >= 0x4E00 && r <= 0x9FFF) || // CJK unified
    (r >= 0x3400 && r <= 0x4DBF) || // ext A
    (r >= 0x20000 && r <= 0x2CEAF) || // ext B-F
    (r >= 0xF900 && r <= 0xFAFF) || // compatibility
    (r >= 0x3040 && r <= 0x30FF) || // hiragana / katakana
    (r >= 0xAC00 && r <= 0xD7AF); // hangul syllables

bool _isWordChar(int r) =>
    (r >= 0x30 && r <= 0x39) ||
    (r >= 0x41 && r <= 0x5A) ||
    (r >= 0x61 && r <= 0x7A) ||
    (r >= 0xC0 && r <= 0x24F) || // latin-1 + extended letters
    r == 0x27 || // apostrophe (don't)
    r == 0x2019;

/// Splits a lyric line into tokens. Punctuation is dropped; whitespace and
/// punctuation mark a pause before the next token.
List<LyricToken> tokenize(String text) {
  final tokens = <LyricToken>[];
  var pendingSpace = false;
  final word = StringBuffer();
  double? pendingTime;
  double? wordTime;

  void flushWord() {
    if (word.isEmpty) return;
    tokens.add(LyricToken(word.toString(), spaceBefore: pendingSpace && tokens.isNotEmpty, time: wordTime));
    word.clear();
    pendingSpace = false;
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
    if (_isCjk(rune)) {
      flushWord();
      tokens.add(LyricToken(ch, spaceBefore: pendingSpace && tokens.isNotEmpty, time: pendingTime));
      pendingSpace = false;
      pendingTime = null;
    } else if (_isWordChar(rune)) {
      if (word.isEmpty) {
        wordTime = pendingTime;
        pendingTime = null;
      }
      word.write(ch);
    } else {
      // whitespace / punctuation
      flushWord();
      pendingSpace = true;
    }
    i += len;
  }
  flushWord();
  return tokens;
}

/// Parses LRC text. Lines are sorted by time; empty lyric lines (used in
/// LRC files to mark the end of a phrase) close the previous line.
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
  // LRC offset: positive values make lyrics appear earlier.
  entries.sort((a, b) => a.$1.compareTo(b.$1));
  stops.sort();
  final lines = <LyricLine>[];
  for (final e in entries) {
    final tokens = tokenize(e.$2);
    if (tokens.isEmpty) {
      errors.add('歌词“${e.$2}”中没有可识别的字');
      continue;
    }
    final start = (e.$1 - offset).clamp(0.0, double.infinity).toDouble();
    final shifted = <LyricToken>[
      for (final t in tokens)
        LyricToken(t.text, spaceBefore: t.spaceBefore, time: t.time == null ? null : t.time! - offset)
    ];
    lines.add(LyricLine(start: start, text: e.$2, tokens: shifted));
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
  return LrcParseResult(lines, metadata, errors);
}
