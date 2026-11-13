import 'dart:math' as math;
import 'package:flutter/material.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../dsp/pitch.dart';
import '../practice/scoring.dart';

/// Colours of the pitch graph.
class PitchGraphColors {
  const PitchGraphColors({
    required this.background,
    required this.grid,
    required this.gridStrong,
    required this.label,
    required this.note,
    required this.noteActive,
    required this.contour,
    required this.lyric,
    required this.great,
    required this.ok,
    required this.off,
    required this.free,
    required this.playhead,
    this.textStyle = const TextStyle(),
  });

  final Color background, grid, gridStrong, label, note, noteActive, contour, lyric;
  final Color great, ok, off, free, playhead;

  /// Base style for text drawn by the painter (inherits the app font).
  final TextStyle textStyle;

  factory PitchGraphColors.of(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final dark = Theme.of(context).brightness == Brightness.dark;
    return PitchGraphColors(
      background: dark ? const Color(0xFF101418) : const Color(0xFFF7F8FA),
      grid: cs.onSurface.withValues(alpha: 0.06),
      gridStrong: cs.onSurface.withValues(alpha: 0.16),
      label: cs.onSurface.withValues(alpha: 0.55),
      note: dark ? const Color(0xFF5B7FA8) : const Color(0xFF9DB6D6),
      noteActive: cs.primary,
      contour: cs.onSurface.withValues(alpha: 0.28),
      lyric: cs.onSurface.withValues(alpha: 0.9),
      great: const Color(0xFF22A06B),
      ok: const Color(0xFFE2A400),
      off: const Color(0xFFE5484D),
      free: cs.tertiary,
      playhead: cs.secondary,
      textStyle: DefaultTextStyle.of(context).style.merge(Theme.of(context).textTheme.bodySmall),
    );
  }

  Color verdict(PitchVerdict v) => switch (v) {
        PitchVerdict.great => great,
        PitchVerdict.ok => ok,
        PitchVerdict.off => off,
        PitchVerdict.noReference => free,
      };

  /// Colour for a token's score (0..100).
  Color score(double s) => s >= 80 ? great : (s >= 60 ? ok : off);
}

/// Draws the reference melody (one bar per note, labelled with its
/// character), the reference contour, the singer's trail and a playhead.
class PitchGraphPainter extends CustomPainter {
  PitchGraphPainter({
    required this.reference,
    required this.t0,
    required this.t1,
    required this.midiLo,
    required this.midiHi,
    required this.colors,
    this.contour,
    this.user = const [],
    this.playhead,
    this.tokenScores,
    this.transpose = 0,
    this.showNoteLabels = true,
    this.gutter = 30,
    super.repaint,
  });

  final SongReference? reference;
  final double t0, t1;
  final double midiLo, midiHi;
  final PitchGraphColors colors;
  final PitchTrack? contour;
  final List<UserPoint> user;
  final double? playhead;

  /// Scores per token (colours the bars after they were sung).
  final Map<RefToken, double>? tokenScores;
  final int transpose;
  final bool showNoteLabels;
  final double gutter;

  static final _textCache = <String, TextPainter>{};

  TextPainter _text(String s, double size, Color color, {FontWeight weight = FontWeight.w500}) {
    final key = '$s|$size|${color.toARGB32()}|${weight.value}|${colors.textStyle.fontFamily}';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 600) _textCache.clear();
      return TextPainter(
        text: TextSpan(
            text: s,
            style: colors.textStyle.copyWith(fontSize: size, color: color, fontWeight: weight, height: 1.0)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = colors.background);
    final plotW = w - gutter;
    double x(double t) => gutter + (t - t0) / (t1 - t0) * plotW;
    double y(double m) => h - (m - midiLo) / (midiHi - midiLo) * h;
    final semitone = h / (midiHi - midiLo);

    // Semitone grid with note names.
    final grid = Paint()..strokeWidth = 1;
    for (var m = midiLo.ceil(); m <= midiHi.floor(); m++) {
      final isC = m % 12 == 0;
      grid.color = isC ? colors.gridStrong : colors.grid;
      final yy = y(m.toDouble());
      canvas.drawLine(Offset(gutter, yy), Offset(w, yy), grid);
      if (showNoteLabels && (isC || semitone >= 11 && const {0, 4, 7}.contains(m % 12))) {
        final tp = _text(noteName(m.toDouble()), 9, colors.label);
        tp.paint(canvas, Offset(2, yy - tp.height / 2));
      }
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(gutter, 0, plotW, h));

    // Reference contour.
    final c = contour;
    if (c != null && c.length > 0) {
      final path = Path();
      var open = false;
      final f0 = math.max(0, (t0 / c.hopSeconds).floor());
      final f1 = math.min(c.length, (t1 / c.hopSeconds).ceil() + 1);
      final step = math.max(1, ((f1 - f0) / (plotW * 1.5)).floor());
      for (var f = f0; f < f1; f += step) {
        final m = c.midi[f];
        if (m <= 0) {
          open = false;
          continue;
        }
        final p = Offset(x(f * c.hopSeconds), y(m + transpose));
        if (open) {
          path.lineTo(p.dx, p.dy);
        } else {
          path.moveTo(p.dx, p.dy);
          open = true;
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1.4
            ..color = colors.contour);
    }

    // Reference notes + lyrics.
    final ref = reference;
    if (ref != null) {
      final barH = math.max(5.0, math.min(14.0, semitone * 0.8));
      final notePaint = Paint();
      for (final line in ref.lines) {
        if (line.end < t0 - 1 || line.start > t1 + 1) continue;
        for (final tok in line.tokens) {
          if (tok.end < t0 || tok.start > t1) continue;
          final active = playhead != null && playhead! >= tok.start && playhead! < tok.end;
          final scored = tokenScores?[tok];
          final color = scored != null && !scored.isNaN
              ? colors.score(scored)
              : (active ? colors.noteActive : colors.note);
          notePaint.color = color.withValues(alpha: active ? 1 : 0.85);
          for (final n in tok.notes) {
            final r = RRect.fromRectAndRadius(
              Rect.fromLTRB(x(n.start), y(n.midi + transpose) - barH / 2, math.max(x(n.end), x(n.start) + 3),
                  y(n.midi + transpose) + barH / 2),
              Radius.circular(barH / 2),
            );
            canvas.drawRRect(r, notePaint);
          }
          // Character label above its first note (or at the line baseline).
          final anchorMidi = tok.notes.isNotEmpty ? tok.notes.first.midi + transpose : midiLo + 1.5;
          final tp = _text(tok.text, 13, active ? colors.noteActive : colors.lyric,
              weight: active ? FontWeight.w700 : FontWeight.w500);
          final lx = x(tok.start);
          var ly = y(anchorMidi) - barH / 2 - tp.height - 2;
          if (ly < 0) ly = y(anchorMidi) + barH / 2 + 2;
          tp.paint(canvas, Offset(lx, ly));
        }
      }
    }

    // Singer's trail.
    if (user.isNotEmpty) {
      final dot = Paint()..strokeCap = StrokeCap.round;
      final seg = Paint()
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round;
      UserPoint? prev;
      for (final p in user) {
        if (p.time < t0 - 0.05 || p.time > t1 + 0.05) {
          prev = null;
          continue;
        }
        if (p.midi <= 0) {
          prev = null;
          continue;
        }
        final pt = Offset(x(p.time), y(p.midi));
        final col = colors.verdict(p.verdict);
        if (prev != null && (p.time - prev.time) < 0.05 && (p.midi - prev.midi).abs() < 1.5) {
          seg.color = col;
          canvas.drawLine(Offset(x(prev.time), y(prev.midi)), pt, seg);
        } else {
          dot.color = col;
          canvas.drawCircle(pt, 2, dot);
        }
        prev = p;
      }
    }

    // Playhead.
    final ph = playhead;
    if (ph != null && ph >= t0 && ph <= t1) {
      final px = x(ph);
      canvas.drawLine(
          Offset(px, 0),
          Offset(px, h),
          Paint()
            ..color = colors.playhead
            ..strokeWidth = 2);
    }
    canvas.restore();
  }

  @override
  bool shouldRepaint(PitchGraphPainter old) =>
      old.t0 != t0 ||
      old.t1 != t1 ||
      old.midiLo != midiLo ||
      old.midiHi != midiHi ||
      old.playhead != playhead ||
      old.user != user ||
      old.user.length != user.length ||
      old.reference != reference ||
      old.tokenScores != tokenScores ||
      old.transpose != transpose;
}

/// Picks a comfortable vertical range around [lo]..[hi].
(double, double) paddedRange(double lo, double hi, {double minSpan = 14}) {
  var a = lo - 3, b = hi + 3;
  if (b - a < minSpan) {
    final mid = (a + b) / 2;
    a = mid - minSpan / 2;
    b = mid + minSpan / 2;
  }
  return (a, b);
}

/// A static image of a whole line (used in lists).
class LinePitchGraph extends StatelessWidget {
  const LinePitchGraph({
    super.key,
    required this.reference,
    required this.line,
    this.contour,
    this.tokenScores,
    this.height = 90,
  });

  final SongReference reference;
  final RefLine line;
  final PitchTrack? contour;
  final Map<RefToken, double>? tokenScores;
  final double height;

  @override
  Widget build(BuildContext context) {
    var lo = double.infinity, hi = -double.infinity;
    for (final n in line.notes) {
      lo = math.min(lo, n.midi);
      hi = math.max(hi, n.midi);
    }
    if (lo > hi) {
      final r = reference.pitchRange;
      lo = r.$1;
      hi = r.$2;
    }
    final (a, b) = paddedRange(lo, hi, minSpan: 10);
    final start = line.start - 0.25, end = math.max(line.end, line.start + 1) + 0.25;
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: PitchGraphPainter(
          reference: SongReference(lines: [line], duration: reference.duration),
          contour: contour,
          t0: start,
          t1: end,
          midiLo: a,
          midiHi: b,
          colors: PitchGraphColors.of(context),
          tokenScores: tokenScores,
          gutter: 26,
        ),
      ),
    );
  }
}
