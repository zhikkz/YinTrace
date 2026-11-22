import 'dart:convert';

import 'package:flutter/services.dart';

import 'lrc.dart';
import 'lyrics_language.dart';

bool isMandarinToken(String text) =>
    text.runes.length == 1 && isIdeograph(text.runes.first);

class MandarinReadings {
  MandarinReadings._(
    this._characters,
    this._simplified,
    this._phrases,
    this._longestPhrase,
  );

  final Map<String, List<String>> _characters;
  final Map<String, String> _simplified;
  final Map<String, List<String>> _phrases;
  final int _longestPhrase;

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
    var longestPhrase = 1;

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
        if (length > longestPhrase) longestPhrase = length;
      }
    }

    return MandarinReadings._(characters, simplified, phrases, longestPhrase);
  }

  Iterable<String> alternatives(String char) =>
      _characters[char] ?? _characters[_simplified[char]] ?? const [];

  /// Use the longest unambiguous phrase that fits within the current run of Mandarin.
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
    final simplified = StringBuffer(
      _simplified[tokens[start].text] ?? tokens[start].text,
    );
    List<String>? longest;
    for (
      var index = start + 1;
      index < tokens.length && index - start < _longestPhrase;
      index++
    ) {
      final token = tokens[index];
      if (token.pauseBefore || !isMandarinToken(token.text)) break;
      original.write(token.text);
      simplified.write(_simplified[token.text] ?? token.text);
      longest =
          _phrases[original.toString()] ??
          _phrases[simplified.toString()] ??
          longest;
    }
    return longest;
  }
}
