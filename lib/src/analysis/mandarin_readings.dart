import 'dart:convert';

import 'package:flutter/services.dart';

import 'lrc.dart';
import 'lyrics_language.dart';
import 'mandarin_lyric_rules.dart';

bool isMandarinToken(String text) =>
    text.runes.length == 1 && isIdeograph(text.runes.first);

typedef _Word = (int end, List<String> reading);

class MandarinReadings {
  MandarinReadings._(
    this._characters,
    this._simplified,
    this._phrases,
    this._words,
    this._lookahead,
  );

  final Map<String, List<String>> _characters;
  final Map<String, String> _simplified;
  final Map<String, List<String>> _phrases;
  final Set<String> _words;
  final int _lookahead;

  static Future<MandarinReadings>? _shared;
  static Future<List<String>> Function() _readTables = bundledTables;

  static Future<MandarinReadings> load() => _shared ??= _load();

  static Future<List<String>> bundledTables() => Future.wait([
    rootBundle.loadString('assets/mandarin/unihan-readings.tsv'),
    rootBundle.loadString('assets/mandarin/cc-cedict-readings.tsv'),
    rootBundle.loadString('assets/mandarin/cc-cedict-words.tsv'),
  ]);

  /// Flutter assets belong to the root isolate. Each worker parses and caches
  /// the source strings on first use.
  static void initializeWorker(Future<List<String>> Function() readTables) =>
      _readTables = readTables;

  static Future<MandarinReadings> _load() async {
    final [unihan, cedict, wordsTable] = await _readTables();
    final characters = <String, List<String>>{};
    final simplified = <String, String>{};
    final phrases = <String, List<String>>{...mandarinLyricWords};
    final words = <String>{};
    var lookahead = 2;

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
        phrases.putIfAbsent(word, () => reading.split(' '));
        if (length > lookahead) lookahead = length;
      }
    }
    for (final word in const LineSplitter().convert(wordsTable)) {
      if (word.startsWith('#')) continue;
      words.add(word);
      // UTF-16 length is an upper bound on the number of ideographs.
      if (word.length > lookahead) lookahead = word.length;
    }

    return MandarinReadings._(
      characters,
      simplified,
      phrases,
      words,
      lookahead,
    );
  }

  Iterable<String> alternatives(String char) =>
      _characters[char] ?? _characters[_simplified[char]] ?? const [];

  /// Syllables supplied by these tables and the original lyric rules.
  Set<String> get syllables => {
    for (final reading in _characters.values) ...reading,
    for (final reading in _phrases.values)
      ...reading.where((value) => value != '-'),
    ...mandarinLyricSyllables,
  };

  /// Resolve each run independently to preserve pauses and non-Mandarin tokens.
  Map<int, String> forTokens(List<LyricToken> tokens) {
    final readings = <int, String>{};
    var start = 0;
    while (start < tokens.length) {
      if (!isMandarinToken(tokens[start].text)) {
        start++;
        continue;
      }
      var end = start + 1;
      while (end < tokens.length &&
          !tokens[end].pauseBefore &&
          isMandarinToken(tokens[end].text)) {
        end++;
      }
      _readRun(tokens, start, end, readings);
      start = end;
    }
    return readings;
  }

  List<String>? _lookup(String word) =>
      _phrases[word] ?? (_words.contains(word) ? const [] : null);

  void _readRun(
    List<LyricToken> tokens,
    int start,
    int end,
    Map<int, String> readings,
  ) {
    final count = end - start;
    final original = List.generate(count, (i) => tokens[start + i].text);
    final simplified = [for (final char in original) _simplified[char] ?? char];
    final text = original.join();
    final simpleText = simplified.join();
    final offsets = _offsets(original);
    final sameSpelling = text == simpleText;
    final simpleOffsets = sameSpelling ? offsets : _offsets(simplified);

    final words = List.generate(count, (_) => <_Word>[]);
    final wordStarts = List.filled(count + 1, false);
    final wordEnds = List.filled(count + 1, false);
    for (var from = 0; from < count; from++) {
      for (var to = from + 2; to <= count && to - from <= _lookahead; to++) {
        final word = text.substring(offsets[from], offsets[to]);
        final simpleWord = sameSpelling
            ? word
            : simpleText.substring(simpleOffsets[from], simpleOffsets[to]);
        final match = word == simpleWord
            ? _lookup(word)
            : mandarinLyricWords[simpleWord] ??
                  _lookup(word) ??
                  _lookup(simpleWord);
        if (match == null) continue;
        words[from].add((to, match));
        wordStarts[from] = wordEnds[to] = true;
      }
    }

    final context = MandarinLyricContext(
      simpleText,
      simplified,
      simpleOffsets,
      wordStarts,
      wordEnds,
    );
    final particles = List.generate(count, context.particleAt);
    final choices = _segment(words, particles);
    final selected = <String?>[
      for (final char in original) alternatives(char).firstOrNull,
    ];
    for (var i = 0; i < count;) {
      final (next, reading) = choices[i];
      for (final (offset, syllable) in reading.indexed) {
        if (syllable != '-') selected[i + offset] = syllable;
      }
      i = next;
    }
    for (var i = 0; i < count; i++) {
      final override = context.readingAt(i);
      if (override == null) continue;
      selected.setRange(i, i + override.length, override);
    }
    for (final (i, reading) in selected.indexed) {
      if (reading != null) readings[start + i] = reading;
    }
  }

  static List<int> _offsets(List<String> chars) {
    var offset = 0;
    return [0, for (final char in chars) offset += char.length];
  }

  /// Minimize unmatched characters, then minimize the number of segments.
  /// Equal paths choose the longer first segment. A recognized particle
  /// cannot be swallowed by a word crossing its position.
  static List<_Word> _segment(
    List<List<_Word>> words,
    List<String?> particles,
  ) {
    final count = words.length;
    final unmatchedCost = count + 1;
    final costs = List.filled(count + 1, 0);
    final choices = List<_Word>.filled(count, (0, const []));
    var nextParticle = count;
    for (var i = count - 1; i >= 0; i--) {
      final particle = particles[i];
      var bestCost = costs[i + 1] + 1;
      var best = (i + 1, const <String>[]);
      if (particle != null) {
        nextParticle = i;
        best = (i + 1, [particle]);
      } else {
        bestCost += unmatchedCost;
        for (final word in words[i]) {
          if (word.$1 > nextParticle) break;
          final cost = costs[word.$1] + 1;
          if (cost <= bestCost) {
            best = word;
            bestCost = cost;
          }
        }
      }
      costs[i] = bestCost;
      choices[i] = best;
    }
    return choices;
  }
}
