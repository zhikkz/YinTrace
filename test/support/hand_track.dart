import 'dart:math' as math;
import 'dart:typed_data';

import 'package:yintrace/src/analysis/pitch_track.dart';

/// The frame step of `analyzePitch`.
const handHop = 128 / 22050;

/// One sung character of a pitch track built by hand: voiced from [start]
/// to [end] at [midi] ([midi2] from [split] on), after [gap] seconds of a
/// voiceless consonant. A level dip of [dip] dB at its start stands for a
/// voiced consonant (m, n, l, r).
class HandChar {
  const HandChar(this.start, this.end, this.midi, {this.gap = 0, this.midi2, this.split, this.dip = 0});
  final double start, end, midi, gap, dip;
  final double? midi2, split;
}

PitchTrack handTrack(List<HandChar> chars, double seconds, {double hop = handHop}) {
  final n = (seconds / hop).ceil();
  final midi = Float32List(n), db = Float32List(n)..fillRange(0, n, -100);
  for (var f = 0; f < n; f++) {
    final t = f * hop;
    for (final c in chars) {
      if (t >= c.start - c.gap && t < c.start) db[f] = -45;
      if (t < c.start || t >= c.end) continue;
      var m = c.midi2 != null && t >= c.split! ? c.midi2! : c.midi;
      // A little vibrato on held notes, as singers do.
      if (t - c.start > 0.2) m += 0.3 * math.sin(2 * math.pi * 5.5 * (t - c.start));
      midi[f] = m;
      db[f] = -20 - (t - c.start < 0.05 ? c.dip * (1 - (t - c.start) / 0.05) : 0);
    }
  }
  return PitchTrack(hopSeconds: hop, midi: midi, rmsDb: db, aperiodicity: Float32List(n));
}
