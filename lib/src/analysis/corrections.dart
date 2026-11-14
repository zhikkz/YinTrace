import 'dart:math' as math;

import '../dsp/pitch.dart';
import 'pitch_track.dart';
import 'reference.dart';

/// A note for [token], which has no detected pitch, so the user can tune
/// it: the original singer's median pitch inside the token when the
/// contour has some, otherwise the nearest note of the line (or C4).
RefNote suggestNote(RefToken token, RefLine line, PitchTrack? contour) {
  var midi = double.nan;
  if (contour != null && contour.length > 0) {
    final a = (token.start / contour.hopSeconds).floor().clamp(0, contour.length).toInt();
    final b = (token.end / contour.hopSeconds).ceil().clamp(0, contour.length).toInt();
    final voiced = [
      for (var f = a; f < b; f++)
        if (contour.midi[f] > 0) contour.midi[f].toDouble(),
    ];
    if (voiced.length >= 3) midi = median(voiced);
  }
  if (midi.isNaN) {
    var best = double.infinity;
    for (final t in line.tokens) {
      if (identical(t, token) || t.notes.isEmpty) continue;
      final d = math.min((t.start - token.end).abs(), (token.start - t.end).abs());
      if (d < best) {
        best = d;
        midi = t.meanMidi;
      }
    }
  }
  if (midi.isNaN) midi = 60;
  return RefNote(start: token.start, end: math.max(token.end, token.start + 0.1), midi: midi.roundToDouble());
}

/// Gives [token] a note the user can tune (see [suggestNote]).
void addManualNote(RefToken token, RefLine line, PitchTrack? contour) {
  if (token.notes.isNotEmpty) return;
  token
    ..notes = [suggestNote(token, line, contour)]
    ..manual = true
    ..shift = 0;
}
