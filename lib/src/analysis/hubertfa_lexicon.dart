import 'dart:convert';
import 'dart:io';

import 'package:kana_kit/kana_kit.dart';
import 'package:pinyin/pinyin.dart';

import 'lrc.dart';
import 'lyrics_language.dart';

const silencePhone = 0;
const unknownPhone = -1;

bool isMandarinToken(String text) => text.runes.length == 1 && isIdeograph(text.runes.first);

final _toneNumber = RegExp(r'[0-5]$');
final _combiningTones = RegExp(r'[\u0300\u0301\u0304\u030c]');
const _marked = 'āáǎàēéěèīíǐìōóǒòūúǔùǖǘǚǜü';
const _unmarked = 'aaaaeeeeiiiioooouuuuvvvvv';

/// The model's syllable dictionaries use unmarked pinyin and spell ü as v.
String normalizePinyin(String text) {
  final lower = text.trim().toLowerCase().replaceAll('u:', 'v').replaceAll('u\u0308', 'v');
  final plain = lower.replaceAll(_combiningTones, '').replaceFirst(_toneNumber, '');
  return plain.split('').map((c) {
    final i = _marked.indexOf(c);
    return i < 0 ? c : _unmarked[i];
  }).join();
}

/// Phrase-aware readings within each uninterrupted run of Mandarin tokens.
Map<int, String> mandarinPinyin(List<LyricToken> tokens) {
  final readings = <int, String>{};
  var i = 0;
  while (i < tokens.length) {
    if (!isMandarinToken(tokens[i].text)) {
      i++;
      continue;
    }
    final start = i++;
    while (i < tokens.length && !tokens[i].pauseBefore && isMandarinToken(tokens[i].text)) {
      i++;
    }
    final phrase = tokens.getRange(start, i).map((t) => t.text).join();
    try {
      final syllables = PinyinHelper.getPinyin(phrase).split(' ');
      if (syllables.length == i - start) {
        for (final (j, syllable) in syllables.indexed) {
          readings[start + j] = normalizePinyin(syllable);
        }
        continue;
      }
    } on PinyinException {
      // An unknown character can still be surrounded by known ones.
    }
    for (var j = start; j < i; j++) {
      final reading = PinyinHelper.convertToPinyinArray(tokens[j].text, PinyinFormat.WITHOUT_TONE).firstOrNull;
      if (reading != null) readings[j] = normalizePinyin(reading);
    }
  }
  return readings;
}

class HubertFaLexicon {
  HubertFaLexicon._(this.size, this._mandarin, this._english, this._japanese);

  final int size;
  final Map<String, List<int>> _mandarin, _english, _japanese;

  static Future<HubertFaLexicon> load(String modelPath, Iterable<LyricLine> lyrics) async {
    final dir = File(modelPath).parent.path;
    final vocab = jsonDecode(await File('$dir/vocab.json').readAsString()) as Map<String, dynamic>;
    final ids = (vocab['vocab'] as Map).cast<String, int>();
    final size = vocab['vocab_size'] as int;
    if (vocab['language_prefix'] != true || ids['SP'] != silencePhone || ids.values.any((id) => id < 0 || id >= size)) {
      throw const FormatException('HuBERTFA 的音素表与模型不匹配');
    }
    final en = {
      for (final line in lyrics)
        for (final token in line.tokens)
          if (isLatinLetter(token.text.runes.first)) _englishKey(token.text),
    };
    final dictionaries = (vocab['dictionaries'] as Map).cast<String, String>();

    Future<Map<String, List<int>>> read(String language, {Set<String>? only}) async {
      if (only?.isEmpty ?? false) return {};
      final file = File('$dir/${dictionaries[language]}');
      final out = <String, List<int>>{};
      lines:
      await for (final line in file.openRead().transform(utf8.decoder).transform(const LineSplitter())) {
        final tab = line.indexOf('\t');
        if (tab < 0) continue;
        final key = line.substring(0, tab);
        if (only != null && !only.contains(key)) continue;
        final phones = <int>[];
        for (final phone in line.substring(tab + 1).trim().split(' ')) {
          final id = ids['$language/$phone'] ?? ids[phone];
          if (id == null) continue lines;
          phones.add(id);
        }
        if (phones.isNotEmpty && phones.any((id) => id != silencePhone)) out[key] = phones;
      }
      return out;
    }

    final dictionariesByLanguage = await Future.wait([read('zh'), read('en', only: en), read('ja')]);
    return HubertFaLexicon._(size, dictionariesByLanguage[0], dictionariesByLanguage[1], dictionariesByLanguage[2]);
  }

  /// One phone sequence per displayed token. A wildcard uses the model's
  /// speech vs silence and edge scores for a word with no dictionary entry.
  List<List<int>> phones(LyricLine line, LyricsLanguage language, Map<int, String> overrides) {
    final tokens = line.tokens;
    final mandarin = language == LyricsLanguage.japanese ? const <int, String>{} : mandarinPinyin(tokens);
    return [
      for (final (i, token) in tokens.indexed) _tokenPhones(token, mandarin[i], overrides[i]) ?? const [unknownPhone],
    ];
  }

  List<int>? _tokenPhones(LyricToken token, String? pinyin, String? override) {
    if (override != null) {
      final phones = _mandarin[normalizePinyin(override)];
      if (phones == null) throw FormatException('“${token.text}”的拼音“$override”不在模型词典中');
      return phones;
    }
    if (pinyin != null) {
      final phones = _mandarin[pinyin];
      if (phones != null) return phones;
      for (final alternate in PinyinHelper.convertToPinyinArray(token.text, PinyinFormat.WITHOUT_TONE)) {
        if (_mandarin[normalizePinyin(alternate)] case final match?) return match;
      }
      return null;
    }
    if (isLatinLetter(token.text.runes.first)) return _english[_englishKey(token.text)];
    final kana = token.reading ?? token.text;
    if (!kana.runes.every(isKana)) return null;
    return _kanaPhones(kana);
  }

  static String _englishKey(String text) => text.toLowerCase().replaceAll('’', "'");

  static const _kanaKit = KanaKit();

  List<int>? _kanaPhones(String text) {
    final morae = <String>[];
    for (final r in _kanaKit.toHiragana(text).runes) {
      final kana = String.fromCharCode(r);
      if (morae.isNotEmpty && isCombiningKana(r)) {
        morae.last += kana;
      } else {
        morae.add(kana);
      }
    }
    final phones = <int>[];
    for (final kana in morae) {
      if (kana == 'っ' || kana == 'ー') {
        // The preceding vowel may sustain. A sokuon can contain silence.
        if (kana == 'っ' && phones.isNotEmpty && phones.last != silencePhone) phones.add(silencePhone);
        continue;
      }
      final romaji = _kanaKit.toRomaji(kana);
      final reading = _japanese[romaji == "n'" ? 'n' : romaji];
      if (reading == null) return null;
      phones.addAll(reading);
    }
    if (phones.lastOrNull == silencePhone) phones.removeLast();
    return phones.isEmpty ? null : phones;
  }
}
