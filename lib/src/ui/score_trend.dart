import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/song.dart';
import 'theme.dart';

/// Scores of the whole-song runs of [history] (line loops left out), oldest
/// first, at most [last] of them.
List<double> wholeSongScores(List<PracticeRecord> history, {int last = 20}) {
  final scores = [
    for (final r in history)
      if (r.loopLine == null && !r.score.isNaN) r.score,
  ];
  return scores.length > last ? scores.sublist(scores.length - last) : scores;
}

/// Scores of line [line] in [history] (whole runs and loops), oldest first.
List<double> lineScores(List<PracticeRecord> history, int line, {int last = 10}) {
  final scores = [
    for (final r in history)
      if (r.lineScores[line] case final s? when !s.isNaN) s,
  ];
  return scores.length > last ? scores.sublist(scores.length - last) : scores;
}

/// How the whole-song score developed over the recent runs.
class ScoreTrend extends StatelessWidget {
  const ScoreTrend({super.key, required this.history});

  final List<PracticeRecord> history;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final scores = wholeSongScores(history);
    if (scores.length < 2) return const SizedBox.shrink();
    final loops = history.where((r) => r.loopLine != null).length;
    final change = scores.last - scores.first;
    final summary =
        '最近 ${scores.last.round()} 分，比第一次'
        '${change.round() == 0 ? '持平' : '${change > 0 ? '高' : '低'} ${change.abs().round()} 分'}';
    return Semantics(
      label: '得分趋势：最近 ${scores.length} 次整首练习，$summary',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('得分趋势', style: context.type.titleMedium),
              const Spacer(),
              Text(summary, style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 92,
            child: CustomPaint(size: Size.infinite, painter: _TrendPainter(scores, p)),
          ),
          const SizedBox(height: 4),
          Text(
            '最近 ${scores.length} 次整首练习${loops > 0 ? '（另有 $loops 次单句循环，算在每一句里）' : ''}',
            style: context.type.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.scores, this.p);
  final List<double> scores;
  final YtPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 10.0, bottom = 6.0, side = 8.0;
    final h = size.height - top - bottom;
    double y(double s) => top + h * (1 - s.clamp(0, 100) / 100);
    double x(int i) => scores.length == 1 ? size.width / 2 : side + (size.width - 2 * side) * i / (scores.length - 1);

    // The grade boundaries of the score colours.
    final staff = Paint()
      ..color = p.staff
      ..strokeWidth = 1;
    for (final s in [60.0, 80.0]) {
      canvas.drawLine(Offset(0, y(s)), Offset(size.width, y(s)), staff);
    }
    canvas.drawLine(
      Offset(0, y(0)),
      Offset(size.width, y(0)),
      Paint()
        ..color = p.hairline
        ..strokeWidth = 1,
    );

    final path = Path()..moveTo(x(0), y(scores[0]));
    for (var i = 1; i < scores.length; i++) {
      path.lineTo(x(i), y(scores[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p.inkSoft
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6
        ..strokeJoin = StrokeJoin.round,
    );
    for (var i = 0; i < scores.length; i++) {
      final last = i == scores.length - 1;
      canvas.drawCircle(Offset(x(i), y(scores[i])), last ? 5 : 3.2, Paint()..color = p.score(scores[i]));
    }
    // The newest score, next to its dot.
    final label = TextPainter(
      text: TextSpan(
        text: scores.last.round().toString(),
        style: TextStyle(color: p.ink, fontSize: 12, fontWeight: FontWeight.w600, fontFeatures: tabular),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lx = math.min(x(scores.length - 1) - label.width / 2, size.width - label.width);
    final above = y(scores.last) - label.height - 6;
    label.paint(canvas, Offset(lx, above < 0 ? y(scores.last) + 7 : above));
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.scores != scores || old.p != p;
}

/// A line's recent scores as a small sparkline (newest on the right).
class LineScoreSparkline extends StatelessWidget {
  const LineScoreSparkline({super.key, required this.scores, this.width = 52, this.height = 18});

  final List<double> scores;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (scores.length < 2) return const SizedBox.shrink();
    return Semantics(
      label: '这一句最近 ${scores.length} 次：${scores.map((s) => s.round()).join('、')}',
      excludeSemantics: true,
      child: CustomPaint(size: Size(width, height), painter: _SparkPainter(scores, context.yt)),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.scores, this.p);
  final List<double> scores;
  final YtPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    const pad = 3.0;
    double x(int i) => pad + (size.width - 2 * pad) * i / (scores.length - 1);
    double y(double s) => pad + (size.height - 2 * pad) * (1 - s.clamp(0, 100) / 100);
    final path = Path()..moveTo(x(0), y(scores[0]));
    for (var i = 1; i < scores.length; i++) {
      path.lineTo(x(i), y(scores[i]));
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = p.inkFaint
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3
        ..strokeJoin = StrokeJoin.round,
    );
    canvas.drawCircle(Offset(x(scores.length - 1), y(scores.last)), 2.6, Paint()..color = p.score(scores.last));
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.scores != scores || old.p != p;
}
