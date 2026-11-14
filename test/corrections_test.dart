import 'dart:convert';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/corrections.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/dsp/guide_tone.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/scoring.dart';

RefToken tok(String text, double start, double end, [double? midi]) => RefToken(
  text: text,
  start: start,
  end: end,
  notes: midi == null ? [] : [RefNote(start: start, end: end, midi: midi)],
);

SongReference song() => SongReference(
  duration: 10,
  lines: [
    RefLine(
      index: 0,
      text: '风吹过',
      lrcStart: 1,
      tokens: [tok('风', 1, 1.4, 62), tok('吹', 1.5, 1.9, 64), tok('过', 2, 2.4)],
    ),
    RefLine(
      index: 1,
      text: '下雨了',
      lrcStart: 4,
      tokens: [tok('下', 4, 4.4, 67), tok('雨', 4.5, 4.9, 69), tok('了', 5, 5.6, 67)],
    ),
  ],
);

SongReference roundTrip(SongReference r) =>
    SongReference.fromJson(jsonDecode(jsonEncode(r.toJson())) as Map<String, dynamic>);

LivePitch sung(double t, double midi) =>
    LivePitch(songTime: t, clockTime: t, midi: midi, levelDb: -20, playing: true, aperiodicity: 0.05);

void main() {
  test('an octave up is stored as a shift over the detected notes', () {
    final r = song();
    r.lines[0].tokens[1].transpose(12);
    expect(r.lines[0].tokens[1].notes.single.midi, 76);
    final json = r.toJson();
    final stored = (json['lines'] as List)[0]['tokens'][1] as Map<String, dynamic>;
    expect(stored['sh'], 12);
    expect((stored['n'] as List).single['m'], 64, reason: 'the detected pitch is kept');
    final copy = roundTrip(r);
    final t = copy.lines[0].tokens[1];
    expect(t.notes.single.midi, 76);
    expect(t.shift, 12);
    expect(t.corrected, isTrue);
    expect(copy.corrected, isTrue);
    t.restore();
    expect(t.notes.single.midi, 64);
    expect(t.corrected, isFalse);
    expect(roundTrip(copy).lines[0].tokens[1].notes.single.midi, 64);
  });

  test('a note added where none was detected is the singer\'s pitch, and can be removed', () {
    final r = song();
    final line = r.lines[0];
    final contour = PitchTrack(
      hopSeconds: 0.01,
      midi: Float32List.fromList([for (var i = 0; i < 300; i++) i >= 200 && i < 240 ? 65.2 : 0]),
      rmsDb: Float32List(300),
      aperiodicity: Float32List(300),
    );
    final gap = line.tokens[2];
    addManualNote(gap, line, contour);
    expect(gap.manual, isTrue);
    expect(gap.notes.single.midi, 65, reason: 'the contour inside the token, rounded');
    gap.transpose(-1);
    final copy = roundTrip(r).lines[0].tokens[2];
    expect(copy.manual, isTrue);
    expect(copy.shift, 0);
    expect(copy.notes.single.midi, 64);
    copy.restore();
    expect(copy.notes, isEmpty);
    // Without a contour: the nearest note of the line.
    final bare = song().lines[0];
    expect(suggestNote(bare.tokens[2], bare, null).midi, 64);
  });

  test('a token that is not scored is left out of the score and the live target', () {
    final r = song();
    r.lines[1].tokens[1].skip = true;
    final copy = roundTrip(r);
    expect(copy.lines[1].tokens[1].skip, isTrue);
    expect(copy.noteAt(4.7), isNull);
    expect(copy.noteAt(4.2)!.midi, 67);
    final scorer = PracticeScorer(copy);
    for (var t = 4.0; t < 5.6; t += 0.01) {
      scorer.add(sung(t, t >= 4.5 && t < 4.9 ? 60 : copy.noteAt(t)?.midi ?? 67)); // way off on 雨
    }
    final line = scorer.lineResult(1);
    expect(line.tokens[1].attempted, isFalse);
    expect(line.score, greaterThan(95), reason: 'the wrong 雨 does not count');
  });

  test('re-aligned lyrics keep corrections on unchanged lines', () {
    final old = song();
    old.lines[0].tokens[0].transpose(-12);
    old.lines[0].tokens[2].skip = true;
    old.lines[1].tokens[0].transpose(2);
    final fresh = song()
      ..lines[1] = RefLine(
        index: 1,
        text: '下雪了',
        lrcStart: 4,
        tokens: [tok('下', 4, 4.4, 67), tok('雪', 4.5, 4.9, 69), tok('了', 5, 5.6, 67)],
      );
    fresh.applyCorrectionsFrom(old);
    expect(fresh.lines[0].tokens[0].notes.single.midi, 50);
    expect(fresh.lines[0].tokens[2].skip, isTrue);
    expect(fresh.lines[1].tokens[0].notes.single.midi, 67, reason: 'that line was edited');
  });

  test('guide tone has the note\'s pitch and fades in and out', () {
    const sr = 44100;
    final pcm = guideTone([(0.1, 0.6, 69.0)], 0, 0.8, sampleRate: sr);
    expect(pcm.length, (0.8 * sr).round());
    expect(pcm[(0.05 * sr).round()], 0, reason: 'silent before the note');
    expect(pcm[(0.1 * sr).round()].abs(), lessThan(0.01), reason: 'fades in');
    // Count upward zero crossings over the steady part: 440 Hz.
    var crossings = 0;
    final a = (0.2 * sr).round(), b = (0.5 * sr).round();
    for (var i = a + 1; i < b; i++) {
      if (pcm[i - 1] < 0 && pcm[i] >= 0) crossings++;
    }
    expect(crossings / 0.3, closeTo(midiToHz(69), 8));
    final peak = pcm.fold<double>(0, (m, v) => math.max(m, v.abs()));
    expect(peak, inInclusiveRange(0.1, 0.3));
  });
}
