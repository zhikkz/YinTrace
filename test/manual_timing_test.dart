// Setting by hand where a character starts, for when the aligner got it
// wrong (issue #9). Hand-built pitch tracks and lyrics written for these
// tests.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/manual_timing.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/ui/pitch_editor_page.dart' show retimeLineInBackground;

import 'support/hand_track.dart';

/// Three lines; the second is sung 1.2 s before its time stamp says.
const _chars = [
  HandChar(1.00, 1.30, 60, gap: 0.3), // 春
  HandChar(1.40, 1.70, 62, gap: 0.08), // 天
  HandChar(1.80, 2.40, 64, gap: 0.08), // 好
  HandChar(3.80, 4.10, 65, gap: 0.5), // 草
  HandChar(4.20, 4.50, 67, gap: 0.08), // 地
  HandChar(4.60, 4.90, 65, gap: 0.08), // 上
  HandChar(5.00, 5.70, 64, gap: 0.08), // 花
  HandChar(7.00, 7.30, 62, gap: 0.5), // 是
  HandChar(7.40, 8.00, 60, gap: 0.08), // 谁
];
const _lyrics = '[00:00.95]春天好\n[00:05.00]草地上花\n[00:06.95]是谁';

final _track = handTrack(_chars, 9);
final _lines = parseLrc(_lyrics).lines;

List<double> _startsOf(SongReference r) => [for (final t in r.tokens) t.start];

void _expectOnTime(SongReference r, {double within = 0.03}) {
  final got = _startsOf(r);
  for (var i = 0; i < _chars.length; i++) {
    expect(got[i], closeTo(_chars[i].start, within), reason: 'character $i');
  }
}

void main() {
  test('a pin puts its character there, and the characters around it follow', () {
    // With the time stamp 1.2 s late, the end of the first line takes the
    // start of the second, and the second slides late.
    final plain = buildReference(_track, _lines);
    expect(plain.lines[1].tokens.first.start, greaterThan(4.1));
    expect(plain.lines[0].tokens.last.start, greaterThan(3));
    // Setting where “草” starts puts both lines right.
    final fixed = buildReference(_track, _lines, pins: {(1, 0): 3.80});
    _expectOnTime(fixed);
    expect(fixed.lines[1].tokens.first.pinned, 3.80);
    expect(fixed.tokens.where((t) => t.pinned != null), hasLength(1));
  });

  test('editing a line moves the line before only where the pin overlaps it', () {
    final plain = buildReference(_track, _lines);
    final lines = linesOfReference(plain, _lyrics);
    // The pin is before the misplaced end of the first line: that line is
    // aligned again too, and both come right.
    _expectOnTime(retimeLine(_track, lines, plain, 1, {0: 3.80}));
    // Correcting the first line instead leaves the second as it was.
    final first = retimeLine(_track, lines, plain, 0, {1: 1.40});
    for (var i = 0; i < 3; i++) {
      expect(first.lines[0].tokens[i].start, closeTo(_chars[i].start, 0.03), reason: 'character $i');
    }
    for (final k in [1, 2]) {
      expect(_startsOf(SongReference(lines: [first.lines[k]], duration: 9)),
          _startsOf(SongReference(lines: [plain.lines[k]], duration: 9)));
    }
  });

  test('the lines that are not edited stay exactly as they are, however they were aligned', () {
    // Aligned differently from what the aligner does now (as by an older
    // version), then one line edited.
    const options = AlignOptions(earlySlack: 0.3, lateSlack: 0.6, gridFrames: 3);
    final old = buildReference(_track, _lines, options: options);
    final edited = retimeLine(_track, linesOfReference(old, _lyrics), old, 2, {});
    for (final k in [0, 1]) {
      for (final (i, t) in old.lines[k].tokens.indexed) {
        final u = edited.lines[k].tokens[i];
        expect(u.start, closeTo(t.start, 1e-6), reason: 'line $k token $i');
        // The last character before the edited line may end differently.
        if (k == 1 && i == old.lines[k].tokens.length - 1) continue;
        expect(u.end, closeTo(t.end, 1e-6), reason: 'line $k token $i');
        expect([for (final n in u.notes) (n.start, n.end, n.midi)], [for (final n in t.notes) (n.start, n.end, n.midi)]);
      }
    }
  });

  test('a pin that cannot be kept is dropped and changes nothing else', () {
    final plain = buildReference(_track, _lines);
    final onlyFirst = buildReference(_track, _lines, pins: {(1, 0): 3.80});
    // Too close after another pin: the second one goes.
    final crowded = buildReference(_track, _lines, pins: {(1, 0): 3.80, (1, 1): 3.805});
    expect(_startsOf(crowded), _startsOf(onlyFirst));
    expect(crowded.lines[1].tokens[1].pinned, isNull);
    // No room before it for the characters it follows: aligned as if unset.
    final early = buildReference(_track, _lines, pins: {(0, 2): 0.001});
    expect(_startsOf(early), _startsOf(plain));
    expect(early.tokens.any((t) => t.pinned != null), isFalse);
    // Outside the song.
    expect(_startsOf(buildReference(_track, _lines, pins: {(2, 0): 99})), _startsOf(plain));
  });

  test('of two pins, only the one without room is dropped', () {
    final both = buildReference(_track, _lines, pins: {(1, 0): 3.80, (0, 2): 0.001});
    expect(_startsOf(both), _startsOf(buildReference(_track, _lines, pins: {(1, 0): 3.80})));
    expect(both.lines[1].tokens[0].pinned, 3.80);
    expect(both.lines[0].tokens[2].pinned, isNull);
  });

  test('the re-alignment the phone runs in the background gives the same result', () async {
    final plain = buildReference(_track, _lines);
    final lines = linesOfReference(plain, _lyrics);
    final here = retimeLine(_track, lines, plain, 1, {0: 3.80});
    final there = await retimeLineInBackground(_track, lines, plain, 1, {0: 3.80});
    expect(jsonEncode(there.toJson()), jsonEncode(here.toJson()));
    _expectOnTime(there);
  });

  test('a line left unsung does not unsettle the line after it', () {
    // The middle line's stamp finds no voice: its characters are spread
    // evenly from it, the last one past where the next line really starts.
    const chars = [
      HandChar(1.00, 1.30, 60, gap: 0.3),
      HandChar(1.40, 1.70, 62, gap: 0.08),
      HandChar(1.80, 2.40, 64, gap: 0.08),
      HandChar(6.00, 6.30, 62, gap: 0.5),
      HandChar(6.40, 7.00, 60, gap: 0.08),
    ];
    const lyrics = '[00:00.95]春天好\n[00:05.00]草地上花开\n[00:06.50]是谁';
    final track = handTrack(chars, 8);
    final lines = parseLrc(lyrics).lines;
    // As an older version might have left it: “是” 0.1 s late.
    final old = buildReference(track, lines, pins: {(2, 0): 6.1});
    old.lines[2].tokens[0].pinned = null;
    expect(old.lines[1].tokens.every((t) => t.notes.isEmpty), isTrue);
    expect(old.lines[1].tokens.last.start, greaterThan(old.lines[2].tokens.first.start));
    final edited = retimeLine(track, linesOfReference(old, lyrics), old, 0, {1: 1.40});
    for (final (i, t) in old.lines[2].tokens.indexed) {
      final u = edited.lines[2].tokens[i];
      expect(u.start, closeTo(t.start, 1e-6), reason: 'token $i');
      expect(u.end, closeTo(t.end, 1e-6), reason: 'token $i');
    }
    expect(edited.lines[0].tokens[2].start, closeTo(1.8, 0.03));
  });

  test('a character pinned before a silence takes the voice after it', () {
    // “是” set 0.4 s before its voice, in the silence after the line before.
    final r = buildReference(_track, _lines, pins: {(1, 0): 3.80, (2, 0): 6.6});
    final t = r.lines[2].tokens[0];
    expect(t.pinned, 6.6);
    expect(t.slotStart, 6.6);
    expect(t.start, closeTo(7.0, 0.02));
    expect(t.notes, isNotEmpty);
    expect(t.meanMidi, closeTo(62, 0.6));
  });

  test('a pin aligns a line whose time stamp found no voice', () {
    // The last line's stamp is far past its singing: nothing is sung there,
    // so it gets evenly spaced characters without pitch.
    const lyrics = '[00:00.95]春天好\n[00:03.70]草地上花\n[00:08.60]是谁';
    final lines = parseLrc(lyrics).lines;
    final plain = buildReference(_track, lines);
    expect(plain.lines[2].tokens.every((t) => t.notes.isEmpty), isTrue);
    final fixed = buildReference(_track, lines, pins: {(2, 0): 7.0});
    expect(fixed.lines[2].tokens[0].start, closeTo(7.0, 0.02));
    expect(fixed.lines[2].tokens[1].start, closeTo(7.4, 0.03));
    expect(fixed.lines[2].tokens.every((t) => t.notes.isNotEmpty), isTrue);
  });

  test('where a start can be set: between pins, at most into the neighbouring lines', () {
    final r = buildReference(_track, _lines, pins: {(1, 0): 3.80});
    // Line 1's second token: after its pinned first one, and before the last
    // character of the line after.
    final (lo, hi) = pinRange(r, 1, 1);
    expect(lo, closeTo(3.80 + 0.06, 1e-9));
    expect(hi, closeTo(r.lines[2].tokens[1].start - 0.06 * 4, 1e-9));
    // The first token of line 0: from the start of the song.
    expect(pinRange(r, 0, 0).$1, 0);
    // Line 2's first token: no further back than line 1's first character.
    expect(pinRange(r, 2, 0).$1, closeTo(3.80 + 0.06 * 4, 1e-9));
  });

  test('a pin is kept in the reference file and counts as a correction', () {
    final r = buildReference(_track, _lines, pins: {(1, 0): 3.80});
    final copy = SongReference.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);
    final t = copy.lines[1].tokens[0];
    expect(t.pinned, 3.80);
    expect(t.corrected, isTrue);
    expect(copy.corrected, isTrue);
    expect(pinsOf(copy), {(1, 0): 3.80});
    t.restore();
    expect(t.pinned, isNull);
    expect(t.corrected, isFalse);
  });

  test('after the lyrics change, pins stay with their lines', () {
    final r = buildReference(_track, _lines, pins: {(1, 0): 3.80, (2, 0): 6.9});
    // A line added before, the last line rewritten.
    final fresh = parseLrc('[00:00.20]啦\n[00:00.95]春天好\n[00:05.00]草地上花\n[00:06.95]是我').lines;
    expect(carriedPins(r, fresh), {(2, 0): 3.80});
    expect(carriedPins(buildReference(_track, _lines), fresh), isEmpty);
  });

  test('the lyric lines of a reference, also where its lines no longer parse the same', () {
    final r = buildReference(_track, _lines);
    final same = linesOfReference(r, _lyrics);
    expect([for (final l in same) l.text], [for (final l in _lines) l.text]);
    // Imported before translations were recognised: the translation is a
    // line of the reference of its own, but parses into the line above now.
    final old = buildReference(_track, parseLrc('$_lyrics\n[00:06.95]Who is it').lines.take(3).toList());
    final withExtra = SongReference(
      lines: [
        ...old.lines,
        RefLine(index: 3, text: 'Who is it', lrcStart: 6.95, tokens: [
          for (final w in ['Who', 'is', 'it']) RefToken(text: w, start: 6.95, end: 7, notes: []),
        ]),
      ],
      duration: 9,
    );
    final lines = linesOfReference(withExtra, '$_lyrics\n[00:06.95]Who is it');
    expect(lines, hasLength(4));
    expect(lines[3].text, 'Who is it');
    expect([for (final t in lines[3].tokens) t.text], ['Who', 'is', 'it']);
    expect(lines[2].text, '是谁');
  });
}
