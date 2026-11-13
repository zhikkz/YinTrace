import 'dart:math' as math;

/// MIDI note number (fractional) for a frequency in Hz.
double hzToMidi(double hz) => 69 + 12 * math.log(hz / 440) / math.ln2;

/// Frequency in Hz of a (fractional) MIDI note number.
double midiToHz(double midi) => 440 * math.pow(2, (midi - 69) / 12).toDouble();

/// Signed distance in cents from [reference] to [value] (both MIDI).
double centsBetween(double value, double reference) => (value - reference) * 100;

/// Distance in semitones ignoring octave errors, in the range [-6, 6).
double pitchClassDistance(double value, double reference) {
  var d = (value - reference) % 12;
  if (d >= 6) d -= 12;
  if (d < -6) d += 12;
  return d;
}

const _sharpNames = ['C', 'C♯', 'D', 'D♯', 'E', 'F', 'F♯', 'G', 'G♯', 'A', 'A♯', 'B'];

/// Note name such as `A4` or `C♯3` for a MIDI note number.
String noteName(double midi) {
  final n = midi.round();
  final name = _sharpNames[n % 12];
  final octave = (n ~/ 12) - 1;
  return '$name$octave';
}

/// Simplified jianpu-style degree relative to C (1..7 with sharps).
String solfegeName(double midi) {
  const names = ['1', '♯1', '2', '♯2', '3', '4', '♯4', '5', '♯5', '6', '♯6', '7'];
  return names[midi.round() % 12];
}

/// Median of a list (does not modify the input).
double median(List<double> values) {
  if (values.isEmpty) return double.nan;
  final s = List<double>.from(values)..sort();
  final m = s.length ~/ 2;
  return s.length.isOdd ? s[m] : 0.5 * (s[m - 1] + s[m]);
}
