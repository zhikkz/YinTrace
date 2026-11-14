import 'dart:math' as math;
import 'dart:typed_data';

/// A small-room reverb for a sung voice: mono in, stereo out (wet signal
/// only). The classic Schroeder–Moorer structure: parallel comb filters with
/// a low-pass in their feedback (high frequencies die out first, like in a
/// room), then all-pass filters in series to thicken the echo density. The
/// right channel uses slightly longer delays than the left for width.
class Reverb {
  Reverb({int sampleRate = 44100, this.feedback = 0.84, this.damping = 0.3}) {
    final scale = sampleRate / 44100;
    int len(int base, int spread) => math.max(1, ((base + spread) * scale).round());
    for (final spread in const [0, _stereoSpread]) {
      _combs.add([for (final d in _combDelays) _Comb(len(d, spread))]);
      _allpasses.add([for (final d in _allpassDelays) _Allpass(len(d, spread))]);
    }
  }

  // Mutually prime delays (samples at 44.1 kHz): 25–37 ms combs, 5–13 ms
  // all-passes.
  static const _combDelays = [1117, 1187, 1279, 1361, 1423, 1489, 1559, 1621];
  static const _allpassDelays = [557, 443, 337, 227];
  static const _stereoSpread = 23;
  static const _inputGain = 0.015;

  /// Comb feedback: how long the room rings.
  final double feedback;

  /// Low-pass in the feedback: how fast the highs die out.
  final double damping;
  final _combs = <List<_Comb>>[];
  final _allpasses = <List<_Allpass>>[];

  /// Wet output for [input] (plus [tail] samples of ring-out after it) into
  /// [left] and [right], which must hold `input.length + tail` samples.
  void process(Float32List input, Float32List left, Float32List right, {int tail = 0}) {
    final n = input.length + tail;
    assert(left.length >= n && right.length >= n);
    const block = 4096;
    final x = Float32List(block);
    for (var at = 0; at < n; at += block) {
      final m = math.min(block, n - at);
      for (var k = 0; k < m; k++) {
        final i = at + k;
        x[k] = i < input.length ? input[i] * _inputGain : 0;
      }
      for (var ch = 0; ch < 2; ch++) {
        final out = ch == 0 ? left : right;
        out.fillRange(at, at + m, 0);
        for (final c in _combs[ch]) {
          c.run(x, out, at, m, feedback, damping);
        }
        for (final a in _allpasses[ch]) {
          a.run(out, at, m);
        }
      }
    }
  }
}

class _Comb {
  _Comb(int length) : _buf = Float32List(length);
  final Float32List _buf;
  int _i = 0;
  double _low = 0;

  /// Adds this comb's output for x[0..m) to out[at..at+m).
  void run(Float32List x, Float32List out, int at, int m, double feedback, double damping) {
    final buf = _buf, len = buf.length;
    var i = _i;
    var low = _low;
    for (var k = 0; k < m; k++) {
      final y = buf[i];
      low = y * (1 - damping) + low * damping;
      buf[i] = x[k] + low * feedback;
      if (++i == len) i = 0;
      out[at + k] += y;
    }
    _i = i;
    _low = low;
  }
}

class _Allpass {
  _Allpass(int length) : _buf = Float32List(length);
  final Float32List _buf;
  int _i = 0;

  /// Filters io[at..at+m) in place.
  void run(Float32List io, int at, int m) {
    final buf = _buf, len = buf.length;
    var i = _i;
    for (var k = 0; k < m; k++) {
      final x = io[at + k];
      final b = buf[i];
      buf[i] = x + b * 0.5;
      io[at + k] = b - x;
      if (++i == len) i = 0;
    }
    _i = i;
  }
}
