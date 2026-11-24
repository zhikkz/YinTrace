import 'unihan_onsets.dart';

/// How a sung syllable starts, from its Mandarin initial.
enum OnsetClass {
  /// b p f d t g k h j q x zh ch sh z c s: a voiceless consonant gap.
  unvoiced,

  /// m n l r: voicing continues, the level dips.
  voiced,

  /// Vowel, y- or w- onsets: often only a pitch or timbre change.
  vowel,

  /// Not a known Chinese character (e.g. a Latin word).
  unknown,
}

final Map<int, OnsetClass> _table = () {
  final m = <int, OnsetClass>{};
  for (final r in unvoicedMandarinOnsets.runes) {
    m[r] = OnsetClass.unvoiced;
  }
  for (final r in voicedMandarinOnsets.runes) {
    m[r] = OnsetClass.voiced;
  }
  return m;
}();

bool _isCjk(int r) => (r >= 0x4E00 && r <= 0x9FFF) || (r >= 0x3400 && r <= 0x4DBF);

/// Onset class of a lyric token (a single character or a word).
OnsetClass onsetClassOf(String token) {
  if (token.isEmpty) return OnsetClass.unknown;
  final r = token.runes.first;
  final c = _table[r];
  if (c != null) return c;
  return _isCjk(r) ? OnsetClass.vowel : OnsetClass.unknown;
}
