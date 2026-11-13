import 'package:flutter/material.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../library/song.dart';
import '../practice/scoring.dart';
import 'app.dart';
import 'pitch_graph.dart';

/// Per-line / per-character feedback after (or during) a run. Pops with a
/// line index when the user wants to loop that line.
class ResultsSheet extends StatelessWidget {
  const ResultsSheet({super.key, required this.scorer, this.record, this.contour});

  final PracticeScorer scorer;
  final PracticeRecord? record;
  final PitchTrack? contour;

  @override
  Widget build(BuildContext context) {
    final results = scorer.results();
    final overall = scorer.overallScore(results);
    final attempted = results.where((r) => r.attempted).toList();
    final theme = Theme.of(context);
    final colors = PitchGraphColors.of(context);
    final problems = attempted.expand((r) => r.problems).toList()
      ..sort((a, b) => a.score.compareTo(b.score));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.75,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(formatScore(overall),
                  style: theme.textTheme.displayMedium?.copyWith(
                      color: overall.isNaN ? null : colors.score(overall), fontWeight: FontWeight.w700)),
              const SizedBox(width: 8),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(attempted.isEmpty ? '还没有唱到有音高的句子' : '已唱 ${attempted.length} 句'),
              ),
            ],
          ),
          if (record != null) Text('已保存到练习记录', style: theme.textTheme.bodySmall),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: 12),
            Text('需要加强的字', style: theme.textTheme.titleMedium),
            const SizedBox(height: 6),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: [
                for (final p in problems.take(16))
                  Chip(
                    avatar: CircleAvatar(
                        backgroundColor: colors.score(p.score),
                        child: Text(p.token.text, style: const TextStyle(color: Colors.white, fontSize: 12))),
                    label: Text(p.summary),
                  ),
              ],
            ),
          ],
          const SizedBox(height: 12),
          for (final r in attempted) _LineCard(result: r, reference: scorer.reference, contour: contour),
        ],
      ),
    );
  }
}

class _LineCard extends StatelessWidget {
  const _LineCard({required this.result, required this.reference, this.contour});
  final LineResult result;
  final SongReference reference;
  final PitchTrack? contour;

  @override
  Widget build(BuildContext context) {
    final colors = PitchGraphColors.of(context);
    final theme = Theme.of(context);
    final scores = <RefToken, double>{
      for (final t in result.tokens)
        if (t.attempted && !t.score.isNaN) t.token: t.score
    };
    return Card(
      margin: const EdgeInsets.symmetric(vertical: 6),
      clipBehavior: Clip.antiAlias,
      child: InkWell(
        onTap: () => Navigator.of(context).pop(result.line.index),
        child: Padding(
          padding: const EdgeInsets.only(bottom: 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              ListTile(
                dense: true,
                title: Text.rich(TextSpan(children: [
                  for (final t in result.tokens)
                    TextSpan(
                      text: '${t.token.spaceBefore ? ' ' : ''}${t.token.text}',
                      style: TextStyle(
                        fontSize: 17,
                        color: t.attempted && !t.score.isNaN ? colors.score(t.score) : theme.colorScheme.outline,
                      ),
                    ),
                ])),
                trailing: Text(formatScore(result.score),
                    style: theme.textTheme.titleLarge?.copyWith(color: colors.score(result.score))),
                subtitle: Text(result.problems.isEmpty
                    ? '这一句唱得很好'
                    : result.problems.map((p) => '「${p.token.text}」${p.summary}').join('；')),
              ),
              LinePitchGraph(reference: reference, line: result.line, contour: contour, tokenScores: scores, height: 70),
              Padding(
                padding: const EdgeInsets.only(right: 12, top: 4),
                child: Text('点这里单句循环练习', textAlign: TextAlign.right, style: theme.textTheme.labelSmall),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
