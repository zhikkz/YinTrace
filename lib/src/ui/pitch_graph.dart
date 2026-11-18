import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../analysis/lyrics_language.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../dsp/pitch.dart';
import '../practice/scoring.dart';
import 'lyrics_style.dart';
import 'theme.dart';

/// Visual parameters of the pitch graph, derived from the theme.
class PitchGraphStyle {
  const PitchGraphStyle({
    required this.palette,
    required this.textStyle,
    this.tolerance = 50,
    this.language = LyricsLanguage.chinese,
  });

  final YtPalette palette;

  /// Base style for the glyphs drawn on the graph (inherits the app font).
  final TextStyle textStyle;

  /// "On pitch" half width in cents (colours the voice trace).
  final double tolerance;

  /// Language of the lyrics drawn over the notes.
  final LyricsLanguage language;

  factory PitchGraphStyle.of(BuildContext context,
          {double tolerance = 50, LyricsLanguage language = LyricsLanguage.chinese}) =>
      PitchGraphStyle(
        palette: context.yt,
        textStyle: lyricsStyle(DefaultTextStyle.of(context).style.merge(Theme.of(context).textTheme.bodyMedium),
            language)!,
        tolerance: tolerance,
        language: language,
      );
}

/// Draws a melody as it would be written on score paper: one ink stroke per
/// sustained note with its character set above it, the original singer's
/// real contour as a hairline, and the practising singer's voice as a
/// coloured trace (azurite = flat, malachite = on pitch, cinnabar = sharp).
class PitchGraphPainter extends CustomPainter {
  PitchGraphPainter({
    required this.reference,
    required this.t0,
    required this.t1,
    required this.midiLo,
    required this.midiHi,
    required this.style,
    this.contour,
    this.user = const [],
    this.playhead,
    this.tokenScores,
    this.transpose = 0,
    this.showNoteLabels = true,
    this.gutter = 30,
    this.glyphSize = 15,
    this.live = false,
    this.highlight,
    this.revision = 0,
  });

  final SongReference? reference;
  final double t0, t1;
  final double midiLo, midiHi;
  final PitchGraphStyle style;
  final PitchTrack? contour;
  final List<UserPoint> user;
  final double? playhead;

  /// Scores per token: sung characters take the colour of their score.
  final Map<RefToken, double>? tokenScores;
  final int transpose;
  final bool showNoteLabels;
  final double gutter;
  final double glyphSize;

  /// Draw the head of the voice trace (practice / tuner).
  final bool live;

  /// A time span to mark with a light band (the pitch editor's selection).
  final (double, double)? highlight;

  /// Bump to repaint after the reference was changed in place.
  final int revision;

  static final _textCache = <String, TextPainter>{};

  TextPainter _text(String s, double size, Color color, {FontWeight weight = FontWeight.w500}) {
    final key = '$s|$size|${color.toARGB32()}|${weight.value}|${style.textStyle.fontFamily}|${style.language.code}';
    return _textCache.putIfAbsent(key, () {
      if (_textCache.length > 800) _textCache.clear();
      return TextPainter(
        text: TextSpan(
            text: s,
            style: style.textStyle
                .copyWith(fontSize: size, color: color, fontWeight: weight, height: 1.0, letterSpacing: 0)),
        textDirection: TextDirection.ltr,
      )..layout();
    });
  }

  @override
  void paint(Canvas canvas, Size size) {
    final p = style.palette;
    final w = size.width, h = size.height;
    canvas.drawRect(Offset.zero & size, Paint()..color = p.paper);
    final plotW = w - gutter;
    double x(double t) => gutter + (t - t0) / (t1 - t0) * plotW;
    double y(double m) => h - (m - midiLo) / (midiHi - midiLo) * h;
    final semitone = h / (midiHi - midiLo);

    // Staff: a faint line per semitone, stronger on every C.
    final line = Paint()..strokeWidth = 1;
    for (var m = midiLo.ceil(); m <= midiHi.floor(); m++) {
      final isC = m % 12 == 0;
      line.color = isC ? p.staffStrong : p.staff;
      final yy = y(m.toDouble());
      canvas.drawLine(Offset(gutter, yy), Offset(w, yy), line);
      if (showNoteLabels && (isC || (semitone >= 12 && m % 12 == 7))) {
        final tp = _text(noteName(m.toDouble()), 10, p.inkFaint, weight: FontWeight.w500);
        tp.paint(canvas, Offset(gutter - tp.width - 6, yy - tp.height / 2));
      }
    }

    canvas.save();
    canvas.clipRect(Rect.fromLTWH(gutter, 0, plotW, h));

    final hl = highlight;
    if (hl != null) {
      canvas.drawRRect(
          RRect.fromLTRBR(x(hl.$1) - 3, 2, x(hl.$2) + 3, h - 2, const Radius.circular(6)),
          Paint()..color = p.ink.withValues(alpha: 0.07));
    }

    // The original singer's real contour, as a hairline.
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
        final pt = Offset(x(f * c.hopSeconds), y(m + transpose));
        if (open) {
          path.lineTo(pt.dx, pt.dy);
        } else {
          path.moveTo(pt.dx, pt.dy);
          open = true;
        }
      }
      canvas.drawPath(
          path,
          Paint()
            ..style = PaintingStyle.stroke
            ..strokeWidth = 1
            ..color = p.inkFaint.withValues(alpha: 0.7));
    }

    // Reference notes: ink strokes, characters above.
    final ref = reference;
    final stroke = math.max(3.5, math.min(9.0, semitone * 0.5));
    final placed = <Rect>[];
    bool free(Rect r) => !placed.any((q) => q.overlaps(r.inflate(1)));
    if (ref != null) {
      final notePaint = Paint()
        ..strokeCap = StrokeCap.round
        ..strokeWidth = stroke;
      for (final ln in ref.lines) {
        if (ln.end < t0 - 1 || ln.start > t1 + 1) continue;
        for (final tok in ln.tokens) {
          if (tok.end < t0 || tok.start > t1) continue;
          final active = playhead != null && playhead! >= tok.start && playhead! < tok.end;
          final scored = tokenScores?[tok];
          final past = playhead != null && tok.end <= playhead!;
          Color color;
          if (scored != null && !scored.isNaN) {
            // Sung: a light wash of the score colour, so the voice trace
            // drawn on top stays the strongest mark.
            color = Color.alphaBlend(p.score(scored).withValues(alpha: 0.38), p.paper);
          } else if (active) {
            color = p.ink;
          } else {
            color = past ? p.inkFaint : p.noteStrokeFuture;
          }
          // Not scored: a faint, thin stroke.
          notePaint
            ..color = tok.skip ? p.inkFaint.withValues(alpha: 0.5) : color
            ..strokeWidth = tok.skip ? stroke * 0.45 : stroke;
          for (final n in tok.notes) {
            final yy = y(n.midi + transpose);
            final x0 = x(n.start) + stroke / 2, x1 = math.max(x(n.end) - stroke / 2, x0 + 0.5);
            if (active) {
              canvas.drawLine(
                  Offset(x0, yy),
                  Offset(x1, yy),
                  Paint()
                    ..strokeCap = StrokeCap.round
                    ..strokeWidth = stroke + 8
                    ..color = p.ink.withValues(alpha: 0.08));
            }
            canvas.drawLine(Offset(x0, yy), Offset(x1, yy), notePaint);
          }
          final anchor = tok.notes.isNotEmpty ? tok.notes.first.midi + transpose : midiLo + 1.2;
          // Words are longer than characters: smaller, so neighbours fit.
          final tp = _text(tok.text, tok.isWord ? glyphSize * 0.8 : glyphSize,
              tok.skip ? p.inkFaint : (past ? p.inkSoft : p.ink),
              weight: active ? FontWeight.w700 : FontWeight.w500);
          final lx = x(tok.start);
          final above = Rect.fromLTWH(lx, y(anchor) - stroke / 2 - tp.height - 4, tp.width, tp.height);
          final below = Rect.fromLTWH(lx, y(anchor) + stroke / 2 + 4, tp.width, tp.height);
          // Dense passages: move a label under its note, or leave it out.
          final spot = above.top >= 2 && free(above) ? above : (free(below) ? below : null);
          if (spot != null) {
            tp.paint(canvas, spot.topLeft);
            placed.add(spot);
          }
        }
      }
    }

    // The singer's voice: a paper halo under the whole trace first, then
    // the coloured trace, so it reads clearly on top of the notes.
    if (user.isNotEmpty) {
      final segments = <(Offset, Offset, Color)>[];
      final dots = <(Offset, Color)>[];
      UserPoint? prev;
      UserPoint? head;
      for (final pt in user) {
        if (pt.time < t0 - 0.05 || pt.time > t1 + 0.05 || pt.midi <= 0) {
          prev = null;
          continue;
        }
        final cents = pt.cents;
        final col = cents == null ? p.inkSoft : p.deviation(cents, tolerance: style.tolerance);
        final o = Offset(x(pt.time), y(pt.midi));
        if (prev != null && (pt.time - prev.time) < 0.05 && (pt.midi - prev.midi).abs() < 1.5) {
          segments.add((Offset(x(prev.time), y(prev.midi)), o, col));
        } else {
          dots.add((o, col));
        }
        prev = pt;
        head = pt;
      }
      final halo = Paint()
        ..strokeWidth = 7
        ..strokeCap = StrokeCap.round
        ..color = p.paper;
      for (final (a, b, _) in segments) {
        canvas.drawLine(a, b, halo);
      }
      for (final (o, _) in dots) {
        canvas.drawCircle(o, 3.5, halo);
      }
      final seg = Paint()
        ..strokeWidth = 3.4
        ..strokeCap = StrokeCap.round;
      for (final (a, b, col) in segments) {
        seg.color = col;
        canvas.drawLine(a, b, seg);
      }
      for (final (o, col) in dots) {
        canvas.drawCircle(o, 2, Paint()..color = col);
      }
      if (live && head != null && playhead != null && (playhead! - head.time) < 0.6) {
        final o = Offset(x(head.time), y(head.midi));
        final cents = head.cents;
        final col = cents == null ? p.inkSoft : p.deviation(cents, tolerance: style.tolerance);
        canvas.drawCircle(o, 9, Paint()..color = col.withValues(alpha: 0.18));
        canvas.drawCircle(o, 4.5, Paint()..color = col);
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
            ..color = p.ink.withValues(alpha: 0.55)
            ..strokeWidth = 1.2);
      final tri = Path()
        ..moveTo(px - 5, 0)
        ..lineTo(px + 5, 0)
        ..lineTo(px, 6)
        ..close();
      canvas.drawPath(tri, Paint()..color = p.ink);
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
      old.live != live ||
      old.user != user ||
      old.user.length != user.length ||
      old.reference != reference ||
      old.tokenScores != tokenScores ||
      old.transpose != transpose ||
      old.highlight != highlight ||
      old.revision != revision ||
      old.style.palette != style.palette;
}

/// Picks a comfortable vertical range around [lo]..[hi].
(double, double) paddedRange(double lo, double hi, {double minSpan = 14, double pad = 3}) {
  var a = lo - pad, b = hi + pad;
  if (b - a < minSpan) {
    final mid = (a + b) / 2;
    a = mid - minSpan / 2;
    b = mid + minSpan / 2;
  }
  return (a, b);
}

/// A static strip of one lyric line (used in lists).
class LinePitchGraph extends StatelessWidget {
  const LinePitchGraph({
    super.key,
    required this.reference,
    required this.line,
    this.contour,
    this.tokenScores,
    this.height = 96,
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
    // Leave room above the highest note for its character.
    final (a, b) = paddedRange(lo, hi, minSpan: 9, pad: 2);
    final start = line.start - 0.2, end = math.max(line.end, line.start + 1) + 0.2;
    return SizedBox(
      height: height,
      child: CustomPaint(
        size: Size.infinite,
        painter: PitchGraphPainter(
          reference: SongReference(lines: [line], duration: reference.duration, language: reference.language),
          contour: contour,
          t0: start,
          t1: end,
          midiLo: a,
          midiHi: b + 2.5,
          style: PitchGraphStyle.of(context, language: reference.language),
          tokenScores: tokenScores,
          gutter: 0,
          showNoteLabels: false,
          glyphSize: 13,
        ),
      ),
    );
  }
}

/// The whole song's melody as a thin ink line ("fingerprint"), for lists.
class MelodyFingerprint extends StatelessWidget {
  const MelodyFingerprint({super.key, required this.notes, this.height = 22});

  /// (start, end, midi) of every note.
  final List<(double, double, double)> notes;
  final double height;

  @override
  Widget build(BuildContext context) => SizedBox(
      height: height, child: CustomPaint(size: Size.infinite, painter: _FingerprintPainter(notes, context.yt)));
}

class _FingerprintPainter extends CustomPainter {
  _FingerprintPainter(this.notes, this.palette);
  final List<(double, double, double)> notes;
  final YtPalette palette;

  @override
  void paint(Canvas canvas, Size size) {
    if (notes.isEmpty) return;
    var lo = double.infinity, hi = -double.infinity, first = double.infinity, last = 0.0;
    for (final n in notes) {
      lo = math.min(lo, n.$3);
      hi = math.max(hi, n.$3);
      first = math.min(first, n.$1);
      last = math.max(last, n.$2);
    }
    if (hi - lo < 6) {
      final mid = (hi + lo) / 2;
      lo = mid - 3;
      hi = mid + 3;
    }
    final span = math.max(1e-3, last - first);
    double x(double t) => (t - first) / span * size.width;
    double y(double m) => size.height - 1.5 - (m - lo) / (hi - lo) * (size.height - 3);
    final sorted = [...notes]..sort((a, b) => a.$1.compareTo(b.$1));
    final path = Path();
    (double, double, double)? prev;
    for (final n in sorted) {
      if (prev == null || n.$1 - prev.$2 > 0.6) {
        path.moveTo(x(n.$1), y(n.$3));
      } else {
        path.lineTo(x(n.$1), y(n.$3));
      }
      path.lineTo(math.max(x(n.$2), x(n.$1) + 0.5), y(n.$3));
      prev = n;
    }
    canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.2
          ..strokeJoin = StrokeJoin.round
          ..color = palette.ink.withValues(alpha: 0.55));
  }

  @override
  bool shouldRepaint(_FingerprintPainter old) => old.notes != notes || old.palette != palette;
}
