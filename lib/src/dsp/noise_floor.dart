import 'dart:math' as math;
import 'dart:typed_data';

/// The level of the background, by minimum statistics: the quietest frame
/// level among the last [parts] x [framesPerPart] background frames.
///
/// Only frames the caller deems background are added, so singing does not
/// age the memory: a long sung note neither drags the floor up nor makes it
/// forget the room. A quieter room lowers the floor with its first frame; a
/// louder one raises it once it has lasted for the whole memory.
class NoiseFloor {
  NoiseFloor({required this.framesPerPart, this.parts = 4})
      : assert(framesPerPart > 0 && parts > 0),
        _mins = Float64List(parts)..fillRange(0, parts, double.infinity);

  final int framesPerPart;
  final int parts;
  final Float64List _mins;
  int _filled = 0; // completed parts in [_mins]
  int _next = 0; // where the next completed part goes
  double _current = double.infinity;
  int _count = 0;

  /// Floor in dB, or null before the first background frame.
  double? get db {
    var m = _current;
    for (var i = 0; i < _filled; i++) {
      m = math.min(m, _mins[i]);
    }
    return m.isFinite ? m : null;
  }

  void add(double levelDb) {
    _current = math.min(_current, levelDb);
    if (++_count < framesPerPart) return;
    _mins[_next] = _current;
    _next = (_next + 1) % parts;
    _filled = math.min(parts, _filled + 1);
    _current = double.infinity;
    _count = 0;
  }

  /// Lets a quieter frame lower the floor without counting as background
  /// time (a gap between sung notes: the room was at most this loud).
  void lower(double levelDb) {
    _current = math.min(_current, levelDb);
  }

  /// Makes [levelDb] part of the background at once (a steady sound that
  /// turned out not to be the singer).
  void raiseTo(double levelDb) {
    for (var i = 0; i < _filled; i++) {
      _mins[i] = math.max(_mins[i], levelDb);
    }
    if (_count > 0) _current = math.max(_current, levelDb);
    if (_filled == 0 && _count == 0) {
      _current = levelDb;
      _count = 1;
    }
  }
}
