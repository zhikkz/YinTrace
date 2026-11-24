import 'dart:convert';

import 'package:flutter/services.dart';

import 'lrc.dart';
import 'lyrics_language.dart';

bool isMandarinToken(String text) =>
    text.runes.length == 1 && isIdeograph(text.runes.first);

// Original lyric rules. Only the returned syllables consume tokens. The
// following noun or verb remains available for ordinary dictionary matching.
const _instrument =
    r'(?:[我你他她]的|[这那]把|[一半][天夜])?'
    r'(?:[木电]?吉他|[钢古竖]?琴|琵琶|古筝|和弦|贝斯|曲子|[新旧]曲|老歌)';
const _quantity = r'[一二两三四五六七八九十百千万几数半每这那]';
const _rowContents = r'(?:[清热眼]?泪|诗(?!人|友)|字|文字|歌词|脚印|大雁|代码)';
const _lyricLookahead = 7; // 弹 + aspect + possessive + 木吉他.
final _lyricRules = <String, List<(RegExp, List<String>)>>{
  '弹': [
    (RegExp('弹[着著]$_instrument'), const ['tan', 'zhe']),
    (RegExp('弹[了过起]?$_instrument'), const ['tan']),
  ],
  '行': [
    (RegExp('(?<=$_quantity)行行$_rowContents'), const ['hang', 'hang']),
    (RegExp('(?<=$_quantity)行$_rowContents'), const ['hang']),
    (RegExp('(?<=泪(?:$_quantity|成))行\$'), const ['hang']),
    (RegExp(r'(?<=诗)行$'), const ['hang']),
  ],
  '著': [
    (RegExp(r'(?<=[看听望想抱牵守等])著(?:[我你他她]|音乐|歌声|旋律)'), const ['zhe']),
  ],
  '重': [
    (RegExp('(?:^|(?<=[再又想要我你他她]))重弹$_instrument'), const ['chong', 'tan']),
    (RegExp(r'重重(?:心事|困难|迷雾|阻碍|险阻)'), const ['chong', 'chong']),
    (RegExp(r'重重地[敲砸摔落]'), const ['zhong', 'zhong', 'de']),
  ],
};

class MandarinReadings {
  MandarinReadings._(
    this._characters,
    this._simplified,
    this._phrases,
    this._lookahead,
  );

  final Map<String, List<String>> _characters;
  final Map<String, String> _simplified;
  final Map<String, List<String>> _phrases;
  final int _lookahead;

  static Future<MandarinReadings>? _shared;

  static Future<MandarinReadings> load() => _shared ??= _load();

  static Future<MandarinReadings> _load() async {
    final [unihan, cedict] = await Future.wait([
      rootBundle.loadString('assets/mandarin/unihan-readings.tsv'),
      rootBundle.loadString('assets/mandarin/cc-cedict-readings.tsv'),
    ]);
    final characters = <String, List<String>>{};
    final simplified = <String, String>{};
    final phrases = <String, List<String>>{};
    var lookahead = _lyricLookahead;

    for (final line in const LineSplitter().convert(unihan)) {
      if (line.startsWith('#')) continue;
      final fields = line.split('\t');
      if (fields[1].isNotEmpty) characters[fields[0]] = fields[1].split(' ');
      if (fields.length == 3) simplified[fields[0]] = fields[2];
    }
    for (final line in const LineSplitter().convert(cedict)) {
      if (line.startsWith('#')) continue;
      final [word, reading] = line.split('\t');
      final length = word.runes.length;
      if (length == 1) {
        (characters[word] ??= []).addAll(reading.split(' '));
      } else {
        phrases[word] = reading.split(' ');
        if (length > lookahead) lookahead = length;
      }
    }

    return MandarinReadings._(characters, simplified, phrases, lookahead);
  }

  Iterable<String> alternatives(String char) =>
      _characters[char] ?? _characters[_simplified[char]] ?? const [];

  String _simplify(String text) => _simplified[text] ?? text;

  /// Prefer dictionary phrases, then lyric context, then isolated readings.
  Map<int, String> forTokens(List<LyricToken> tokens) {
    final readings = <int, String>{};
    var index = 0;
    while (index < tokens.length) {
      final char = tokens[index].text;
      if (!isMandarinToken(char)) {
        index++;
        continue;
      }
      final phrase = _phraseAt(tokens, index);
      if (phrase == null) {
        if (alternatives(char).firstOrNull case final reading?) {
          readings[index] = reading;
        }
        index++;
        continue;
      }
      for (final syllable in phrase) {
        readings[index++] = syllable;
      }
    }
    return readings;
  }

  List<String>? _phraseAt(List<LyricToken> tokens, int start) {
    final original = StringBuffer(tokens[start].text);
    final head = _simplify(tokens[start].text);
    final simplified = StringBuffer(head);
    List<String>? longest;
    for (
      var index = start + 1;
      index < tokens.length && index - start < _lookahead;
      index++
    ) {
      final token = tokens[index];
      if (token.pauseBefore || !isMandarinToken(token.text)) break;
      original.write(token.text);
      simplified.write(_simplify(token.text));
      longest =
          _phrases[original.toString()] ??
          _phrases[simplified.toString()] ??
          longest;
    }
    final rules = _lyricRules[head];
    if (longest != null || rules == null) return longest;
    var previous = '';
    for (var i = start - 1; i >= 0 && start - i <= 2; i--) {
      if (tokens[i + 1].pauseBefore || !isMandarinToken(tokens[i].text)) break;
      previous = _simplify(tokens[i].text) + previous;
    }
    final context = '$previous$simplified';
    for (final (pattern, syllables) in rules) {
      if (pattern.matchAsPrefix(context, previous.length) != null) {
        return syllables;
      }
    }
    return null;
  }
}
