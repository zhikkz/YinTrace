import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/practice/scoring.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';

List<UserPoint> _sung(double from, double to, double midi) => [
  for (var t = from; t < to; t += 0.01) UserPoint(t, midi, PitchVerdict.great),
];

void main() {
  group('the practice graph\'s axis', () {
    test('is whole semitones and holds still while the notes in view change a little', () {
      final axis = PitchAxisFollower();
      final first = axis.follow(60.2, 67.4);
      expect(first.$1, first.$1.roundToDouble());
      expect(first.$2, first.$2.roundToDouble());
      expect(first.$1, lessThanOrEqualTo(60.2 - 3));
      expect(first.$2, greaterThanOrEqualTo(67.4 + 3));
      // A note scrolls in one semitone lower, another scrolls out above.
      expect(axis.follow(59.6, 67.4), first);
      expect(axis.follow(59.6, 66.5), first);
    });

    test('grows at once for a note that does not fit, and shrinks when much too big', () {
      final axis = PitchAxisFollower();
      final (lo, hi) = axis.follow(60, 67);
      final grown = axis.follow(52, 67);
      expect(grown.$1, lessThanOrEqualTo(52 - 3));
      expect(grown.$2, hi);
      final back = axis.follow(60, 67);
      expect(back.$1, lo, reason: 'more than two semitones too low: shrinks');
    });

    test('a pitch held by the singer counts, a single wrong reading does not', () {
      final points = [
        ..._sung(1.0, 1.5, 62),
        const UserPoint(1.52, 38, PitchVerdict.off), // an octave slip of the live pitch
        ..._sung(1.54, 2.0, 62.4),
        ..._sung(3.0, 3.2, 50),
      ];
      expect(steadyPitchRange(points, 0, 2.5), (62, 62.4));
      expect(steadyPitchRange(points, 0, 4), (50, 62.4));
      expect(steadyPitchRange(points, 2.5, 2.9), isNull);
      expect(steadyPitchRange([const UserPoint(1, 60, PitchVerdict.great)], 0, 2), isNull);
    });
  });
}
