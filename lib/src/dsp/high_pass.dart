import 'dart:math' as math;
import 'dart:typed_data';

/// A 4th order Butterworth high-pass filter (two cascaded biquads) whose
/// state carries over from one block to the next.
class HighPass {
  HighPass(this.cutoffHz, this.sampleRate) {
    // Butterworth poles of order 4: the two sections' Q values.
    const qs = [0.5411961001461970, 1.3065629648763766];
    final w0 = 2 * math.pi * cutoffHz / sampleRate;
    final cw = math.cos(w0), sw = math.sin(w0);
    for (var s = 0; s < 2; s++) {
      final alpha = sw / (2 * qs[s]);
      final a0 = 1 + alpha;
      _b0[s] = (1 + cw) / 2 / a0;
      _b1[s] = -(1 + cw) / a0;
      _b2[s] = _b0[s];
      _a1[s] = -2 * cw / a0;
      _a2[s] = (1 - alpha) / a0;
    }
  }

  final double cutoffHz;
  final int sampleRate;
  final _b0 = Float64List(2), _b1 = Float64List(2), _b2 = Float64List(2);
  final _a1 = Float64List(2), _a2 = Float64List(2);
  // Transposed direct form II state of each section.
  final _z1 = Float64List(2), _z2 = Float64List(2);

  void reset() {
    _z1.fillRange(0, 2, 0);
    _z2.fillRange(0, 2, 0);
  }

  /// Filters `input[start .. start + count)` into `output[0 .. count)`.
  void process(List<double> input, int start, int count, Float64List output) {
    var z10 = _z1[0], z20 = _z2[0], z11 = _z1[1], z21 = _z2[1];
    final b00 = _b0[0], b10 = _b1[0], b20 = _b2[0], a10 = _a1[0], a20 = _a2[0];
    final b01 = _b0[1], b11 = _b1[1], b21 = _b2[1], a11 = _a1[1], a21 = _a2[1];
    for (var i = 0; i < count; i++) {
      final x = input[start + i];
      final y0 = b00 * x + z10;
      z10 = b10 * x - a10 * y0 + z20;
      z20 = b20 * x - a20 * y0;
      final y1 = b01 * y0 + z11;
      z11 = b11 * y0 - a11 * y1 + z21;
      z21 = b21 * y0 - a21 * y1;
      output[i] = y1;
    }
    // Keep denormals out of the state during digital silence.
    _z1[0] = z10.abs() < 1e-30 ? 0 : z10;
    _z2[0] = z20.abs() < 1e-30 ? 0 : z20;
    _z1[1] = z11.abs() < 1e-30 ? 0 : z11;
    _z2[1] = z21.abs() < 1e-30 ? 0 : z21;
  }
}
