import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';
import 'package:yintrace/src/ui/theme.dart';

PitchTrack track(List<double> midi, {double hop = 0.01}) => PitchTrack(
  hopSeconds: hop,
  midi: Float32List.fromList(midi),
  rmsDb: Float32List(midi.length),
  aperiodicity: Float32List(midi.length),
);

Path contour(PitchTrack t, {int step = 1, int start = 0, int? end}) =>
    pitchContourPath(
      t,
      startFrame: start,
      endFrame: end ?? t.length,
      step: step,
      position: (f, m) => Offset(f.toDouble(), m),
    );

List<(Offset, Offset)> strokes(Path path) => [
  for (final m in path.computeMetrics())
    (
      m.getTangentForOffset(0)!.position,
      m.getTangentForOffset(m.length)!.position,
    ),
];

void main() {
  test('the painter preserves a skipped silence frame when zoomed out', () {
    final t = track([for (var i = 0; i < 80; i++) i == 3 ? 0 : 60]);
    final canvas = TestRecordingCanvas();
    PitchGraphPainter(
      reference: null,
      contour: t,
      t0: 0,
      t1: t.duration,
      midiLo: 48,
      midiHi: 84,
      gutter: 0,
      showNoteLabels: false,
      style: const PitchGraphStyle(
        palette: YtPalette.light,
        textStyle: TextStyle(),
      ),
    ).paint(canvas, const Size(10, 100));
    final drawn = canvas.invocations.singleWhere(
      (c) => c.invocation.memberName == #drawPath,
    );
    final parts = strokes(drawn.invocation.positionalArguments.first as Path);
    expect(parts, hasLength(2));
    expect(parts.first.$2.dx, closeTo(2 / 80 * 10, 1e-5));
    expect(parts.last.$1.dx, closeTo(4 / 80 * 10, 1e-5));
    expect(parts.last.$2.dx, closeTo(79 / 80 * 10, 1e-5));
  });

  for (final step in [1, 2, 4, 100]) {
    test('silence splits equal notes at sampling step $step', () {
      final t = track([60, 60, 60, 0, 60, 60, 60, 60, 60]);
      expect(strokes(contour(t, step: step)), [
        (const Offset(0, 60), const Offset(2, 60)),
        (const Offset(4, 60), const Offset(8, 60)),
      ]);
    });

    test(
      'jumps hidden between sampled vertices split strokes at step $step',
      () {
        final t = track([60, 60, 72, 72, 60, 60, 60, 60]);
        expect(strokes(contour(t, step: step)), [
          (const Offset(0, 60), const Offset(1, 60)),
          (const Offset(2, 72), const Offset(3, 72)),
          (const Offset(4, 60), const Offset(7, 60)),
        ]);
        expect(
          t.midi[2],
          72,
          reason: 'display breaks must not change stored pitch',
        );
      },
    );
  }

  test('continuous glides remain connected even when decimated endpoints differ by an octave', () {
    final t = track([for (var i = 0; i <= 24; i++) 60 + i * 0.5]);
    for (final step in [1, 12, 100]) {
      final parts = strokes(contour(t, step: step));
      expect(parts, [(const Offset(0, 60), const Offset(24, 72))]);
    }
  });

  test('empty, silent and isolated samples do not draw connecting lines', () {
    for (final values in <List<double>>[
      [],
      [0, 0],
      [60],
      [0, 60, 0],
      [60, 0, 72],
    ]) {
      expect(strokes(contour(track(values))), isEmpty);
    }
  });

  test(
    'invalid pitches break the path without producing invalid coordinates',
    () {
      final t = track([
        60,
        60,
        double.nan,
        60,
        60,
        double.infinity,
        60,
        60,
        -1,
        60,
        60,
      ]);
      expect(strokes(contour(t, step: 100)), [
        (const Offset(0, 60), const Offset(1, 60)),
        (const Offset(3, 60), const Offset(4, 60)),
        (const Offset(6, 60), const Offset(7, 60)),
        (const Offset(9, 60), const Offset(10, 60)),
      ]);
    },
  );

  test(
    'visible range retains stroke endpoints and ignores offscreen samples',
    () {
      final t = track([72, 60, 60, 60, 60, 60, 72]);
      expect(strokes(contour(t, step: 100, start: 1, end: 6)), [
        (const Offset(1, 60), const Offset(5, 60)),
      ]);
      expect(strokes(contour(t, start: 10)), isEmpty);
    },
  );

  test('replacing the contour repaints an otherwise unchanged graph', () {
    PitchGraphPainter painter(PitchTrack t) => PitchGraphPainter(
      reference: null,
      contour: t,
      t0: 0,
      t1: 1,
      midiLo: 48,
      midiHi: 84,
      style: const PitchGraphStyle(
        palette: YtPalette.light,
        textStyle: TextStyle(),
      ),
    );
    final a = track([60, 60]);
    expect(painter(a).shouldRepaint(painter(a)), isFalse);
    expect(painter(track([72, 72])).shouldRepaint(painter(a)), isTrue);
  });
}
