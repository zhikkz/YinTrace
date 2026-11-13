import 'dart:math' as math;
import 'dart:typed_data';

import 'package:fftea/fftea.dart';

/// Real-input FFT of even size [n], computed with a complex FFT of size n/2.
///
/// Spectra are exchanged as separate real/imaginary arrays holding the
/// n/2 + 1 non-redundant bins, like `numpy.fft.rfft` / `irfft`.
class RealFft {
  RealFft(this.n)
      : assert(n >= 4 && n.isEven, 'n must be even'),
        _m = n ~/ 2,
        _fft = FFT(n ~/ 2),
        _buf = Float64x2List(n ~/ 2),
        _cos = Float64List(n ~/ 2 + 1),
        _sin = Float64List(n ~/ 2 + 1) {
    for (var k = 0; k <= _m; k++) {
      final a = -2 * math.pi * k / n;
      _cos[k] = math.cos(a);
      _sin[k] = math.sin(a);
    }
  }

  final int n;
  final int _m;
  final FFT _fft;
  final Float64x2List _buf;
  // W^k = exp(-2*pi*i*k/n)
  final Float64List _cos;
  final Float64List _sin;

  int get bins => _m + 1;

  /// Forward transform of `x[offset .. offset+n)` (samples beyond the end
  /// of [x] are treated as zero). Writes `bins` values into [re]/[im].
  void forward(List<double> x, Float64List re, Float64List im, [int offset = 0]) {
    final m = _m;
    final buf = _buf;
    final len = x.length;
    for (var j = 0; j < m; j++) {
      final i0 = offset + 2 * j;
      final a = i0 < len ? x[i0] : 0.0;
      final b = i0 + 1 < len ? x[i0 + 1] : 0.0;
      buf[j] = Float64x2(a, b);
    }
    _fft.inPlaceFft(buf);
    final z0 = buf[0];
    // k = 0 and k = m (Z[m] == Z[0]).
    re[0] = z0.x + z0.y;
    im[0] = 0;
    re[m] = z0.x - z0.y;
    im[m] = 0;
    for (var k = 1; k < m; k++) {
      final zk = buf[k];
      final zc = buf[m - k];
      // E = (Z[k] + conj(Z[m-k])) / 2 ; O = (Z[k] - conj(Z[m-k])) / (2i)
      final er = 0.5 * (zk.x + zc.x);
      final ei = 0.5 * (zk.y - zc.y);
      final dr = 0.5 * (zk.x - zc.x);
      final di = 0.5 * (zk.y + zc.y);
      // (dr + i di) / i = di - i dr
      final or = di;
      final oi = -dr;
      final c = _cos[k], s = _sin[k];
      re[k] = er + c * or - s * oi;
      im[k] = ei + c * oi + s * or;
    }
  }

  /// Inverse transform (with 1/n scaling) of the `bins` values in
  /// [re]/[im] into `out[offset .. offset+n)`. The imaginary parts of the DC
  /// and Nyquist bins are ignored, matching `numpy.fft.irfft`.
  void inverse(Float64List re, Float64List im, Float64List out, [int offset = 0]) {
    final m = _m;
    final buf = _buf;
    for (var k = 0; k < m; k++) {
      final xr = re[k];
      final xi = k == 0 ? 0.0 : im[k];
      final yr = re[m - k];
      final yi = (m - k) == m ? 0.0 : -im[m - k]; // conj(X[m-k])
      final er = 0.5 * (xr + yr);
      final ei = 0.5 * (xi + yi);
      final dr = 0.5 * (xr - yr);
      final di = 0.5 * (xi - yi);
      // O = D * conj(W^k)
      final c = _cos[k], s = -_sin[k];
      final or = dr * c - di * s;
      final oi = dr * s + di * c;
      // Z = E + i O ; store conj(Z) to compute the inverse with a forward FFT.
      final zr = er - oi;
      final zi = ei + or;
      buf[k] = Float64x2(zr, -zi);
    }
    _fft.inPlaceFft(buf);
    final scale = 1.0 / m;
    for (var j = 0; j < m; j++) {
      final z = buf[j];
      out[offset + 2 * j] = z.x * scale;
      out[offset + 2 * j + 1] = -z.y * scale;
    }
  }
}
