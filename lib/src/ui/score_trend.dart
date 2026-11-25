import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../library/song.dart';
import 'theme.dart';

typedef ScoreInKey = ({double score, int transpose});

/// Recent whole-song or single-line scores, oldest first.
List<ScoreInKey> recentScores(List<PracticeRecord> history, {int? line, required int last}) {
  final scores = <ScoreInKey>[];
  for (final r in history) {
    final score = line == null ? (r.wholeSong ? r.score : null) : r.lineScores[line];
    if (score != null && !score.isNaN) scores.add((score: score, transpose: r.transpose));
  }
  return scores.length > last ? scores.sublist(scores.length - last) : scores;
}

List<double> wholeSongScores(List<PracticeRecord> history, {int last = 20}) =>
    [for (final s in recentScores(history, last: last)) s.score];

List<double> lineScores(List<PracticeRecord> history, int line, {int last = 10}) =>
    [for (final s in recentScores(history, line: line, last: last)) s.score];

/// How the whole-song score developed over the recent runs.
class ScoreTrend extends StatelessWidget {
  const ScoreTrend({super.key, required this.history});

  final List<PracticeRecord> history;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final entries = recentScores(history, last: 20);
    final scores = [for (final s in entries) s.score];
    if (scores.length < 2) return const SizedBox.shrink();
    final loops = history.where((r) => r.loopLine != null).length;
    final partial = history.where((r) => r.loopLine == null && !r.wholeSong).length;
    final others = [if (loops > 0) '$loops 次单句循环', if (partial > 0) '$partial 次没唱完'];
    final change = scores.last - scores.first;
    final summary =
        '最近 ${scores.last.round()} 分${transposeSuffix(entries.last.transpose)}，比第一次'
        '${change.round() == 0 ? '持平' : '${change > 0 ? '高' : '低'} ${change.abs().round()} 分'}';
    return Semantics(
      label: '得分趋势：最近 ${scores.length} 次整首练习，$summary。'
          '${entries.map((s) => '${s.score.round()}${transposeSuffix(s.transpose)}').join('、')}',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text('得分趋势', style: context.type.titleMedium),
              const Spacer(),
              Flexible(child: Text(summary, textAlign: TextAlign.end,
                  style: context.type.bodySmall?.copyWith(fontFeatures: tabular))),
            ],
          ),
          const SizedBox(height: 8),
          SizedBox(
            height: 92,
            child: CustomPaint(size: Size.infinite, painter: _TrendPainter(entries, p)),
          ),
          const SizedBox(height: 4),
          Text(
            '最近 ${scores.length} 次整首练习${others.isEmpty ? '' : '（另有 ${others.join('、')}，算在每一句里）'}',
            style: context.type.labelSmall,
          ),
        ],
      ),
    );
  }
}

class _TrendPainter extends CustomPainter {
  _TrendPainter(this.entries, this.p);
  final List<ScoreInKey> entries;
  final YtPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    const top = 10.0, bottom = 6.0, side = 8.0;
    final scores = [for (final s in entries) s.score];
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
      final point = Offset(x(i), y(scores[i]));
      canvas.drawCircle(point, last ? 5 : 3.2, Paint()..color = p.score(scores[i]));
      final transpose = entries[i].transpose;
      if (transpose != 0) {
        final label = TextPainter(
          text: TextSpan(text: transposeMark(transpose), style: TextStyle(color: p.ink, fontSize: 9)),
          textDirection: TextDirection.ltr,
        )..layout();
        final below = point.dy + 5;
        final labelY = below + label.height <= size.height ? below : point.dy - 5 - label.height;
        final labelX = (point.dx - label.width / 2).clamp(0.0, math.max(0, size.width - label.width)).toDouble();
        label.paint(canvas, Offset(labelX, labelY));
        label.dispose();
      }
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
    final labelY = above < 0 ? y(scores.last) + (entries.last.transpose == 0 ? 7 : 18) : above;
    label.paint(canvas, Offset(lx, labelY));
    label.dispose();
  }

  @override
  bool shouldRepaint(_TrendPainter old) => old.entries != entries || old.p != p;
}

/// A line's recent scores as a small sparkline (newest on the right).
class LineScoreSparkline extends StatelessWidget {
  const LineScoreSparkline({super.key, required this.scores, this.transposes, this.width = 52, this.height = 18});

  final List<double> scores;
  final List<int>? transposes;
  final double width;
  final double height;

  @override
  Widget build(BuildContext context) {
    if (scores.length < 2) return const SizedBox.shrink();
    final keys = transposes;
    final values = [
      for (final (i, score) in scores.indexed) '${score.round()}${transposeSuffix(keys?[i] ?? 0)}',
    ];
    final summary = '这一句最近 ${scores.length} 次：${values.join('、')}';
    return Semantics(
      label: summary,
      excludeSemantics: true,
      child: Tooltip(
        message: summary,
        child: CustomPaint(size: Size(width, height), painter: _SparkPainter(scores, keys, context.yt)),
      ),
    );
  }
}

class _SparkPainter extends CustomPainter {
  _SparkPainter(this.scores, this.transposes, this.p);
  final List<double> scores;
  final List<int>? transposes;
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
    final keys = transposes;
    if (keys != null) {
      final mark = Paint()..color = p.inkSoft;
      for (final (i, key) in keys.indexed) {
        if (key != 0) canvas.drawCircle(Offset(x(i), y(scores[i])), 2, mark);
      }
    }
    canvas.drawCircle(Offset(x(scores.length - 1), y(scores.last)), 2.6, Paint()..color = p.score(scores.last));
  }

  @override
  bool shouldRepaint(_SparkPainter old) => old.scores != scores || old.transposes != transposes || old.p != p;
}
