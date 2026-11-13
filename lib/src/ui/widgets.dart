import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../dsp/pitch.dart';
import 'theme.dart';

/// A horizontal cents meter: azurite (flat) on the left, malachite in the
/// middle, cinnabar (sharp) on the right.
class PitchMeter extends StatelessWidget {
  const PitchMeter({super.key, required this.cents, this.tolerance = 50, this.range = 100, this.height = 30});

  /// Signed deviation, null when nothing is sung.
  final double? cents;
  final double tolerance;
  final double range;
  final double height;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: _MeterPainter(cents, tolerance, range, context.yt),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.cents, this.tolerance, this.range, this.p);
  final double? cents;
  final double tolerance;
  final double range;
  final YtPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, cy = size.height / 2;
    double x(double c) => w / 2 + c.clamp(-range, range) / range * (w / 2 - 6);
    // The in-tune zone.
    final zone = RRect.fromLTRBR(x(-tolerance), cy - 6, x(tolerance), cy + 6, const Radius.circular(6));
    canvas.drawRRect(zone, Paint()..color = p.malachite.withValues(alpha: 0.14));
    // Track with ticks every 25 cents.
    final track = Paint()
      ..color = p.staffStrong
      ..strokeWidth = 1.5;
    canvas.drawLine(Offset(6, cy), Offset(w - 6, cy), track);
    for (var c = -range; c <= range; c += 25) {
      final big = c == 0;
      canvas.drawLine(Offset(x(c), cy - (big ? 9 : 4)), Offset(x(c), cy + (big ? 9 : 4)),
          Paint()
            ..color = big ? p.inkSoft : p.staffStrong
            ..strokeWidth = big ? 1.5 : 1);
    }
    final c = cents;
    if (c != null) {
      final col = p.deviation(c, tolerance: tolerance);
      final o = Offset(x(c), cy);
      canvas.drawCircle(o, 11, Paint()..color = col.withValues(alpha: 0.18));
      canvas.drawCircle(o, 6.5, Paint()..color = col);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.cents != cents || old.p != p;
}

/// A score numeral with a short pigment rule under it.
class ScoreNumeral extends StatelessWidget {
  const ScoreNumeral({super.key, required this.score, this.size = 28, this.label});

  final double? score;
  final double size;
  final String? label;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final s = score;
    final valid = s != null && !s.isNaN;
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        Text(valid ? s.round().toString() : '–',
            style: TextStyle(
              fontSize: size,
              fontWeight: FontWeight.w300,
              height: 1.0,
              color: valid ? p.ink : p.inkFaint,
              fontFeatures: tabular,
              letterSpacing: -0.5,
            )),
        const SizedBox(height: 4),
        Container(
          width: math.max(14, size * 0.7),
          height: 2.5,
          decoration: BoxDecoration(
            color: valid ? p.score(s) : p.hairline,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        if (label != null) ...[
          const SizedBox(height: 4),
          Text(label!, style: context.type.labelSmall),
        ],
      ],
    );
  }
}

/// Note name with its octave, e.g. "G4", or a dash.
String noteLabel(double? midi) => midi == null || midi <= 0 ? '–' : noteName(midi);

/// "4:19" style duration.
String clock(double seconds) {
  if (seconds.isNaN || seconds < 0) return '–:––';
  final s = seconds.round();
  return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
}
