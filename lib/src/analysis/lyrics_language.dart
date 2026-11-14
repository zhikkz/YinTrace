import 'lrc.dart';
import 'pinyin_initials.dart';

/// The language of a song's lyrics. Lyrics split into the same kind of
/// units in every language (a CJK character or kana, or a Latin word); the
/// language decides how the aligner predicts how each unit starts and how
/// long it lasts, and what the UI calls a unit.
enum LyricsLanguage {
  chinese('zh', '中文'),
  english('en', '英文'),
  japanese('ja', '日文');

  const LyricsLanguage(this.code, this.label);

  /// BCP 47 language code (also stored in reference.json).
  final String code;
  final String label;

  static LyricsLanguage fromCode(String? code) =>
      values.firstWhere((l) => l.code == code, orElse: () => LyricsLanguage.chinese);

  /// What the UI calls one sung unit: a character (字) or a word (词).
  String get unit => this == LyricsLanguage.english ? '词' : '字';
}

bool isKana(int r) =>
    (r >= 0x3041 && r <= 0x309F) || // hiragana
    (r >= 0x30A0 && r <= 0x30FF) || // katakana (with ー)
    (r >= 0x31F0 && r <= 0x31FF) || // small katakana extensions
    (r >= 0xFF66 && r <= 0xFF9F); // halfwidth katakana

bool isIdeograph(int r) =>
    (r >= 0x4E00 && r <= 0x9FFF) ||
    (r >= 0x3400 && r <= 0x4DBF) ||
    (r >= 0x20000 && r <= 0x2CEAF) ||
    (r >= 0xF900 && r <= 0xFAFF) ||
    r == 0x3005 || // 々 (repeats the kanji before it)
    r == 0x3006 || // 〆
    r == 0x3007; // 〇

bool isLatinLetter(int r) =>
    (r >= 0x41 && r <= 0x5A) || (r >= 0x61 && r <= 0x7A) || (r >= 0xC0 && r <= 0x24F && r != 0xD7 && r != 0xF7);

/// Picks the language from the lyric text: any real amount of kana means
/// Japanese; otherwise more Latin words than CJK characters means English.
LyricsLanguage detectLanguage(Iterable<String> lines) {
  var kana = 0, han = 0, words = 0;
  for (final line in lines) {
    var inWord = false;
    for (final r in line.runes) {
      if (isKana(r)) {
        kana++;
      } else if (isIdeograph(r)) {
        han++;
      }
      final letter = isLatinLetter(r) || r == 0x27 || r == 0x2019;
      if (letter && !inWord) words++;
      inWord = letter;
    }
  }
  if (kana >= 3 && kana >= 0.1 * (kana + han)) return LyricsLanguage.japanese;
  if (words > han) return LyricsLanguage.english;
  return LyricsLanguage.chinese;
}

/// Detects the language of parsed lyrics.
LyricsLanguage detectLyricsLanguage(List<LyricLine> lines) => detectLanguage(lines.map((l) => l.text));

// --- Japanese -------------------------------------------------------------

/// Hiragana of a kana (katakana shifted down; others unchanged).
int _hira(int r) => r >= 0x30A1 && r <= 0x30F6 ? r - 0x60 : r;

/// Small kana that join the kana before them into one mora (きょ, ふぁ).
bool isCombiningKana(int r) => 'ぁぃぅぇぉゃゅょゎゕゖ'.runes.contains(_hira(r)) || (r >= 0x31F0 && r <= 0x31FF);

/// Kana that extend the syllable before them instead of starting one:
/// combining small kana, the sokuon (っ) and the long vowel mark (ー).
bool extendsPreviousKana(int r) => isCombiningKana(r) || _hira(r) == 0x3063 || r == 0x30FC;

const _jaVowel = 'あいうえおやゆよわゐゑをぁぃぅぇぉ';
const _jaUnvoiced = 'かきくけこさしすせそたちつてとはひふへほぱぴぷぺぽ';
const _jaVoiced = 'がぎぐげござじずぜぞだぢづでどばびぶべぼなにぬねのまみむめもらりるれろんゔ';

OnsetClass _kanaOnset(int r) {
  final h = String.fromCharCode(_hira(r));
  if (_jaUnvoiced.contains(h)) return OnsetClass.unvoiced;
  if (_jaVoiced.contains(h)) return OnsetClass.voiced;
  if (_jaVowel.contains(h)) return OnsetClass.vowel;
  return OnsetClass.unknown;
}

/// Morae of a kana string: combining small kana add nothing, the sokuon
/// half a mora (it is a short stop when sung).
double kanaMorae(String kana) {
  var m = 0.0;
  for (final r in kana.runes) {
    if (!isKana(r)) continue;
    if (isCombiningKana(r)) continue;
    m += _hira(r) == 0x3063 ? 0.5 : 1;
  }
  return m;
}

/// Average sung morae of a kanji without a reading.
const kanjiMorae = 1.8;

// --- English --------------------------------------------------------------

const _thVoiced = {
  'the',
  'this',
  'that',
  'these',
  'those',
  'they',
  'them',
  'their',
  'there',
  'then',
  'than',
  'thee',
  'thy',
  'though',
  'thus',
  'theirs',
  'themselves',
  'therefore',
};

OnsetClass _englishOnset(String word) {
  final w = word.toLowerCase().replaceAll('’', "'");
  if (w.isEmpty) return OnsetClass.unknown;
  if (w.startsWith('th')) {
    return _thVoiced.contains(w.replaceAll(RegExp(r"'.*$"), '')) ? OnsetClass.voiced : OnsetClass.unvoiced;
  }
  if (w.startsWith('wh')) return OnsetClass.vowel;
  final c = w[0];
  if ('aeiouàáâäèéêëìíîïòóôöùúûü'.contains(c)) return OnsetClass.vowel;
  if ('yw'.contains(c)) return OnsetClass.vowel; // like Mandarin y-/w-
  if ('mnlr'.contains(c)) return OnsetClass.voiced;
  if ('vz'.contains(c)) return OnsetClass.voiced;
  if ('ptkcqfshxbdgj'.contains(c)) return OnsetClass.unvoiced;
  return OnsetClass.unknown;
}

/// Sung syllables of an English word, from its vowel groups (a silent final
/// e does not count).
int englishSyllables(String word) {
  final w = word.toLowerCase().replaceAll(RegExp(r"['’].*$"), '');
  if (w.isEmpty) return 1;
  final groups = RegExp(r'[aeiouyàáâäèéêëìíîïòóôöùúûü]+').allMatches(w).length;
  var n = groups;
  if (n > 1) {
    if (RegExp(r'[^aeiouy]e$').hasMatch(w) && !RegExp(r'[^aeiouy]le$').hasMatch(w)) {
      n--; // "love", "smile" ("little" keeps its -le)
    } else if (RegExp(r'[^aeiouy]es$').hasMatch(w) && !RegExp(r'((s|x|z|ch|sh)es|[cg]es)$').hasMatch(w)) {
      n--; // "comes", "lines" ("kisses", "changes" keep theirs)
    } else if (RegExp(r'[^aeiouy]ed$').hasMatch(w) && !RegExp(r'[td]ed$').hasMatch(w)) {
      n--; // "loved", "turned" ("wanted" keeps its -ed)
    }
  }
  return n < 1 ? 1 : n;
}

// --- Per token ------------------------------------------------------------

bool _latin(String s) => s.isNotEmpty && isLatinLetter(s.runes.first);

/// How the token's syllable starts (what the aligner looks for at its onset).
OnsetClass tokenOnsetClass(LyricToken t, LyricsLanguage language) {
  final text = t.text;
  if (text.isEmpty) return OnsetClass.unknown;
  if (_latin(text)) return _englishOnset(text);
  final r = text.runes.first;
  if (isKana(r)) return _kanaOnset(r);
  if (language == LyricsLanguage.japanese) {
    // A kanji is read by its kana reading when the lyrics give one.
    final reading = t.reading;
    if (reading != null && reading.isNotEmpty) return _kanaOnset(reading.runes.first);
    return OnsetClass.unknown;
  }
  return onsetClassOf(text);
}

/// The syllables the aligner places for a token, each with how it starts
/// and how long it is relative to one syllable (Japanese: mora). A Chinese
/// character is one syllable; an English word has one per vowel group; a
/// kana, or a kanji read by its ruby, one per kana that starts a mora (small
/// kana, っ and ー lengthen the one before). A kanji without a reading in
/// Japanese lyrics is one syllable of average length ([kanjiMorae]).
List<(OnsetClass, double)> tokenSyllables(LyricToken t, LyricsLanguage language) {
  final text = t.text;
  if (text.isEmpty) return const [(OnsetClass.unknown, 1)];
  if (_latin(text)) {
    final n = englishSyllables(text);
    return [(_englishOnset(text), 1), for (var i = 1; i < n; i++) (OnsetClass.unknown, 1)];
  }
  final reading = t.reading;
  final kana = reading != null && reading.isNotEmpty ? reading : (text.runes.every(isKana) ? text : null);
  if (kana != null) {
    final out = <(OnsetClass, double)>[];
    for (final r in kana.runes) {
      if (out.isNotEmpty && extendsPreviousKana(r)) {
        final (cls, w) = out.last;
        out[out.length - 1] = (cls, w + (isCombiningKana(r) ? 0 : (_hira(r) == 0x3063 ? 0.5 : 1)));
      } else {
        out.add((_kanaOnset(r), 1));
      }
    }
    if (out.isNotEmpty) return out;
  }
  return [(tokenOnsetClass(t, language), tokenWeight(t, language))];
}

/// How long the token is sung, relative to one syllable (Japanese: mora).
double tokenWeight(LyricToken t, LyricsLanguage language) {
  final text = t.text;
  if (text.isEmpty) return 1;
  if (_latin(text)) return englishSyllables(text).toDouble();
  final reading = t.reading;
  if (reading != null && reading.isNotEmpty) return _atLeast(kanaMorae(reading));
  var w = 0.0;
  for (final r in text.runes) {
    if (isKana(r)) {
      w += isCombiningKana(r) ? 0 : (_hira(r) == 0x3063 ? 0.5 : 1);
    } else if (isIdeograph(r)) {
      w += language == LyricsLanguage.japanese ? kanjiMorae : 1;
    } else {
      w += 1;
    }
  }
  return _atLeast(w);
}

double _atLeast(double w) => w < 0.5 ? 0.5 : w;
