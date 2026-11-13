import 'dart:math' as math;
import 'dart:typed_data';

int _gcd(int a, int b) {
  while (b != 0) {
    final t = a % b;
    a = b;
    b = t;
  }
  return a.abs();
}

/// Zeroth order modified Bessel function of the first kind.
double besselI0(double x) {
  var sum = 1.0;
  var term = 1.0;
  final q = x * x / 4;
  for (var k = 1; k < 200; k++) {
    term *= q / (k * k);
    sum += term;
    if (term < sum * 1e-17) break;
  }
  return sum;
}

/// Polyphase rational resampler equivalent to `scipy.signal.resample_poly`
/// with its default Kaiser(5.0) anti-aliasing filter. This is what librosa
/// uses for `res_type='polyphase'`.
class PolyphaseResampler {
  factory PolyphaseResampler(int fromRate, int toRate, {double beta = 5.0}) {
    final g = _gcd(fromRate, toRate);
    return PolyphaseResampler._(toRate ~/ g, fromRate ~/ g, beta);
  }

  PolyphaseResampler._(this.up, this.down, double beta)
      : halfLen = 10 * math.max(up, down),
        taps = _design(up, down, beta);

  final int up;
  final int down;
  final int halfLen;
  final Float64List taps;

  static Float64List _design(int up, int down, double beta) {
    final maxRate = math.max(up, down);
    final halfLen = 10 * maxRate;
    final n = 2 * halfLen + 1;
    final cutoff = 1.0 / maxRate; // relative to Nyquist
    final h = Float64List(n);
    final alpha = (n - 1) / 2.0;
    final i0b = besselI0(beta);
    var sum = 0.0;
    for (var i = 0; i < n; i++) {
      final m = i - alpha;
      final x = cutoff * m;
      final sinc = x == 0 ? 1.0 : math.sin(math.pi * x) / (math.pi * x);
      final r = 2.0 * i / (n - 1) - 1.0;
      final w = besselI0(beta * math.sqrt(math.max(0.0, 1 - r * r))) / i0b;
      h[i] = cutoff * sinc * w;
      sum += h[i];
    }
    for (var i = 0; i < n; i++) {
      h[i] = h[i] / sum * up;
    }
    return h;
  }

  int outputLength(int inputLength) {
    final n = inputLength * up;
    return n ~/ down + (n % down != 0 ? 1 : 0);
  }

  /// Resamples `x[start .. start+length)`.
  Float64List process(List<double> x, {int start = 0, int? length}) {
    final len = length ?? x.length - start;
    final outLen = outputLength(len);
    final out = Float64List(outLen);
    if (up == 1 && down == 1) {
      for (var i = 0; i < len; i++) {
        out[i] = x[start + i];
      }
      return out;
    }
    final h = taps;
    final nTaps = h.length;
    for (var j = 0; j < outLen; j++) {
      // y[j] = sum_k h[k] * xUp[t - k], xUp[n] = x[n/up] when up | n.
      final t = j * down + halfLen;
      var k = t % up;
      // first k with (t - k)/up < len  ->  k > t - len*up
      final minK = t - (len - 1) * up;
      if (k < minK) k += ((minK - k + up - 1) ~/ up) * up;
      var acc = 0.0;
      for (; k < nTaps; k += up) {
        final idx = (t - k) ~/ up;
        if (idx < 0) break;
        acc += h[k] * x[start + idx];
      }
      out[j] = acc;
    }
    return out;
  }
}

/// Resamples a mono signal between integer sample rates.
Float64List resample(List<double> x, int fromRate, int toRate) {
  if (fromRate == toRate) return Float64List.fromList(x);
  return PolyphaseResampler(fromRate, toRate).process(x);
}
