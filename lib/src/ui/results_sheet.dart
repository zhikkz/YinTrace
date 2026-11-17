import 'package:flutter/material.dart';

import '../analysis/lyrics_language.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../library/song.dart';
import '../practice/scoring.dart';
import 'lyrics_style.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

/// What the results sheet asks the practice page to do when it closes.
sealed class ResultsAction {
  const ResultsAction();
}

/// Practise this line in a loop.
class LoopLineAction extends ResultsAction {
  const LoopLineAction(this.line);
  final int line;
}

/// Listen back to what was sung: one line, or the whole take.
class ListenBackAction extends ResultsAction {
  const ListenBackAction([this.line]);
  final int? line;
}

/// Keep the take and make a finished track of it.
class ExportTakeAction extends ResultsAction {
  const ExportTakeAction();
}

/// Hear how the original singer sings a line.
class ListenOriginalAction extends ResultsAction {
  const ListenOriginalAction(this.line);
  final int line;
}

/// Feedback after (or during) a run: the overall score, the characters that
/// need work, and every sung line. Pops with a [ResultsAction].
class ResultsSheet extends StatelessWidget {
  const ResultsSheet({super.key, required this.scorer, this.record, this.contour, this.canListen});

  final PracticeScorer scorer;
  final PracticeRecord? record;
  final PitchTrack? contour;

  /// Whether a take can be played back (for a line, or all of it); null
  /// hides listening back.
  final bool Function(int? line)? canListen;

  @override
  Widget build(BuildContext context) {
    final results = scorer.results();
    final overall = scorer.overallScore(results);
    final attempted = results.where((r) => r.attempted).toList();
    final p = context.yt;
    // Each with the line it is in: tapping one practises that line.
    final problems = [
      for (final r in attempted)
        for (final t in r.problems) (r.line.index, t),
    ]..sort((a, b) => a.$2.score.compareTo(b.$2.score));
    return DraggableScrollableSheet(
      expand: false,
      initialChildSize: 0.8,
      maxChildSize: 0.95,
      builder: (context, controller) => ListView(
        controller: controller,
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              Text(overall.isNaN ? '–' : overall.round().toString(),
                  style: context.type.displayLarge?.copyWith(fontFeatures: tabular)),
              const SizedBox(width: 6),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text('分', style: context.type.titleMedium?.copyWith(color: p.inkSoft)),
              ),
              const Spacer(),
              Padding(
                padding: const EdgeInsets.only(bottom: 10),
                child: Text(
                  attempted.isEmpty ? '还没唱到有音高的句子' : '唱了 ${attempted.length} 句',
                  style: context.type.bodyMedium,
                ),
              ),
            ],
          ),
          if (!overall.isNaN)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: _ScoreBar(score: overall),
            ),
          if (record case final record?)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                record.loopLine != null || record.wholeSong
                    ? '已记入这首歌的练习记录'
                    : '已记下每一句的分数。唱完大部分（八成以上）才算一次整首练习，计入最高分和得分趋势',
                style: context.type.labelSmall,
              ),
            ),
          if (canListen?.call(null) ?? false)
            Padding(
              padding: const EdgeInsets.only(top: 16),
              child: Row(
                children: [
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(const ListenBackAction()),
                      icon: const Icon(Icons.headphones_rounded),
                      label: const Text('回听这一遍'),
                    ),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: OutlinedButton.icon(
                      onPressed: () => Navigator.of(context).pop(const ExportTakeAction()),
                      icon: const Icon(Icons.library_music_rounded),
                      label: const Text('制作成品'),
                    ),
                  ),
                ],
              ),
            ),
          if (problems.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('先练这几个${scorer.reference.language.unit}', style: context.type.titleLarge),
            const SizedBox(height: 4),
            Text('点一个${scorer.reference.language.unit}，单独循环练它所在的那一句。', style: context.type.bodySmall),
            const SizedBox(height: 12),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: [
                for (final (line, t) in problems.take(12))
                  _GlyphTile(
                    result: t,
                    language: scorer.reference.language,
                    onTap: () => Navigator.of(context).pop(LoopLineAction(line)),
                  ),
              ],
            ),
            const SizedBox(height: 10),
            _Legend(),
          ],
          if (attempted.isNotEmpty) ...[
            const SizedBox(height: 28),
            Text('每一句', style: context.type.titleLarge),
            const SizedBox(height: 4),
            Text(
              canListen == null
                  ? '点一句，回到练习里单独循环它；点人像听原唱怎么唱。'
                  : '点一句，回到练习里单独循环它；点耳机听你唱的这一句，点人像听原唱怎么唱。',
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 8),
            for (final r in attempted)
              _LineResultRow(
                result: r,
                reference: scorer.reference,
                contour: contour,
                canListen: canListen?.call(r.line.index) ?? false,
              ),
          ],
        ],
      ),
    );
  }
}

class _ScoreBar extends StatelessWidget {
  const _ScoreBar({required this.score});
  final double score;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    return ClipRRect(
      borderRadius: BorderRadius.circular(3),
      child: SizedBox(
        height: 5,
        child: Row(children: [
          Expanded(flex: score.round().clamp(0, 100), child: ColoredBox(color: p.score(score))),
          Expanded(flex: 100 - score.round().clamp(0, 100), child: ColoredBox(color: p.staffStrong)),
        ]),
      ),
    );
  }
}

/// Colour of the main problem of a character.
Color issueColor(YtPalette p, Set<TokenIssue> issues) {
  if (issues.contains(TokenIssue.sharp)) return p.cinnabar;
  if (issues.contains(TokenIssue.flat)) return p.azurite;
  if (issues.contains(TokenIssue.unstable)) return p.gamboge;
  if (issues.contains(TokenIssue.missed)) return p.inkFaint;
  return p.inkSoft;
}

String _shortIssue(TokenResult t) {
  final i = t.issues;
  final c = t.medianCents?.abs().round();
  if (i.contains(TokenIssue.sharp)) return '高 $c';
  if (i.contains(TokenIssue.flat)) return '低 $c';
  if (i.contains(TokenIssue.missed)) return '没唱出';
  if (i.contains(TokenIssue.unstable)) return '不稳';
  if (i.contains(TokenIssue.late)) return '进晚了';
  if (i.contains(TokenIssue.early)) return '抢拍';
  return '';
}

class _GlyphTile extends StatelessWidget {
  const _GlyphTile({required this.result, required this.language, required this.onTap});
  final TokenResult result;
  final LyricsLanguage language;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final color = issueColor(p, result.issues);
    final timing = result.issues.contains(TokenIssue.late) || result.issues.contains(TokenIssue.early);
    final shape = RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(14),
      side: BorderSide(color: color.withValues(alpha: 0.55), width: 1.4),
    );
    return Tooltip(
      message: '「${result.token.text}」${result.summary}，点一下练这一句',
      child: Material(
        color: p.surface,
        shape: shape,
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            width: 68,
            padding: const EdgeInsets.fromLTRB(4, 10, 4, 8),
            child: Column(
              children: [
                // A word shrinks to fit the tile.
                FittedBox(
                  fit: BoxFit.scaleDown,
                  child: Text(
                    result.token.text,
                    maxLines: 1,
                    style: lyricsStyle(
                      TextStyle(fontSize: 30, height: 1.1, fontWeight: FontWeight.w600, color: color),
                      language,
                    ),
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  _shortIssue(result),
                  style: context.type.labelSmall?.copyWith(color: p.inkSoft, fontFeatures: tabular),
                ),
                if (timing && (result.issues.contains(TokenIssue.sharp) || result.issues.contains(TokenIssue.flat)))
                  Text(result.issues.contains(TokenIssue.late) ? '进晚了' : '抢拍', style: context.type.labelSmall),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _Legend extends StatelessWidget {
  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    Widget item(Color c, String t) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 8, height: 8, decoration: BoxDecoration(color: c, shape: BoxShape.circle)),
          const SizedBox(width: 5),
          Text(t, style: context.type.labelSmall),
        ]);
    return Wrap(spacing: 14, runSpacing: 6, children: [
      item(p.cinnabar, '唱高了'),
      item(p.azurite, '唱低了'),
      item(p.gamboge, '不稳'),
      item(p.inkFaint, '没唱出来'),
      Text('数字是音分，100 音分 = 半音', style: context.type.labelSmall),
    ]);
  }
}

class _LineResultRow extends StatelessWidget {
  const _LineResultRow({required this.result, required this.reference, this.contour, this.canListen = false});
  final LineResult result;
  final SongReference reference;
  final PitchTrack? contour;
  final bool canListen;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final scores = <RefToken, double>{
      for (final t in result.tokens)
        if (t.attempted && !t.score.isNaN) t.token: t.score
    };
    final problems = result.problems.toList();
    return InkWell(
      onTap: () => Navigator.of(context).pop(LoopLineAction(result.line.index)),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Expanded(
                  child: Text.rich(TextSpan(children: [
                    for (final (k, t) in result.tokens.indexed)
                      TextSpan(
                        text: '${tokenGap(k > 0 ? result.tokens[k - 1].token : null, t.token)}${t.token.text}',
                        style: lyricsStyle(context.type.titleMedium, reference.language)?.copyWith(
                          color: !t.attempted || t.score.isNaN
                              ? p.inkFaint
                              : (t.issues.isEmpty ? p.ink : issueColor(p, t.issues)),
                        ),
                      ),
                  ])),
                ),
                IconButton(
                  tooltip: '听原唱这一句',
                  visualDensity: VisualDensity.compact,
                  icon: const Icon(Icons.record_voice_over_rounded),
                  onPressed: () => Navigator.of(context).pop(ListenOriginalAction(result.line.index)),
                ),
                if (canListen)
                  IconButton(
                    tooltip: '回听这一句',
                    visualDensity: VisualDensity.compact,
                    icon: const Icon(Icons.headphones_rounded),
                    onPressed: () => Navigator.of(context).pop(ListenBackAction(result.line.index)),
                  ),
                ScoreNumeral(score: result.score, size: 22),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              problems.isEmpty ? '这一句唱得很准' : problems.map((t) => '「${t.token.text}」${t.summary}').join('；'),
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 6),
            LinePitchGraph(reference: reference, line: result.line, contour: contour, tokenScores: scores, height: 76),
          ],
        ),
      ),
    );
  }
}
