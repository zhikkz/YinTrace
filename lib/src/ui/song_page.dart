import 'package:flutter/material.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/services.dart';
import '../import/import_pipeline.dart';
import '../library/song.dart';
import 'import_page.dart' show lyricsHint;
import 'lyrics_style.dart';
import 'pitch_graph.dart';
import 'practice_page.dart';
import 'score_trend.dart';
import 'theme.dart';
import 'widgets.dart';

/// One song, laid out like a score: every lyric line above the melody of
/// its characters. Tap a line to loop it.
class SongPage extends StatefulWidget {
  const SongPage({super.key, required this.songId});
  final String songId;

  @override
  State<SongPage> createState() => _SongPageState();
}

class _SongPageState extends State<SongPage> {
  SongMeta? _meta;
  SongReference? _ref;
  PitchTrack? _track;
  List<PracticeRecord> _history = const [];
  String? _error;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _load();
    }
  }

  Future<void> _load() async {
    final repo = AppScope.of(context).songs;
    try {
      final meta = await repo.load(widget.songId);
      final ref = await repo.loadReference(widget.songId);
      final track = await repo.loadPitchTrack(widget.songId);
      final history = await repo.loadHistory(widget.songId);
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _ref = ref;
        _track = track;
        _history = history;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _practice({int? line}) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PracticePage(meta: _meta!, reference: _ref!, contour: _track, loopLine: line),
    ));
    await _load();
  }

  Future<void> _editLyrics() async {
    final controller = TextEditingController(text: _meta!.lyrics);
    final ok = await showModalBottomSheet<bool>(
      context: context,
      isScrollControlled: true,
      builder: (ctx) => Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, MediaQuery.viewInsetsOf(ctx).bottom + 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('修改歌词', style: ctx.type.headlineSmall),
            const SizedBox(height: 6),
            Text(
              '改完会用已经测好的音高重新对齐每个${_ref!.language.unit}，不需要重新分离人声。'
              '${_ref!.corrected ? '没改动的句子里，你校正过的音高会保留。' : ''}',
              style: ctx.type.bodySmall,
            ),
            const SizedBox(height: 14),
            TextField(
              controller: controller,
              minLines: 8,
              maxLines: 14,
              decoration: const InputDecoration(hintText: lyricsHint),
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新对齐')),
          ],
        ),
      ),
    );
    if (ok != true || !mounted) return;
    try {
      await realignSong(AppScope.of(context).songs, widget.songId, controller.text);
      await _load();
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    }
  }

  Future<void> _delete() async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这首歌？'),
        content: const Text('分离出的人声、伴奏、音高图和练习记录都会删除，无法恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('保留')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: Text('删除', style: TextStyle(color: context.yt.cinnabar)),
          ),
        ],
      ),
    );
    if (ok != true || !mounted) return;
    await AppScope.of(context).songs.delete(widget.songId);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final meta = _meta, ref = _ref;
    if (_error != null) {
      return Scaffold(
          appBar: AppBar(),
          body: Padding(padding: const EdgeInsets.all(24), child: Text('这首歌的数据读取失败：$_error')));
    }
    if (meta == null || ref == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final lastLineScores = <int, double>{};
    for (final r in _history) {
      lastLineScores.addAll(r.lineScores);
    }
    final p = context.yt;
    return Scaffold(
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(meta.title),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => v == 'edit' ? _editLyrics() : _delete(),
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'edit', child: Text('修改歌词')),
                  PopupMenuItem(value: 'delete', child: Text('删除这首歌')),
                ],
              ),
              const SizedBox(width: 8),
            ],
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        if (meta.artist.isNotEmpty) Text(meta.artist, style: context.type.bodyLarge),
                        const SizedBox(height: 4),
                        Text(
                          '${clock(meta.duration)}，${ref.lines.length} 句'
                          '${meta.accompanimentFile == null ? '，没有伴奏' : ''}',
                          style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
                        ),
                      ],
                    ),
                  ),
                  ScoreNumeral(score: meta.bestScore, size: 34, label: meta.practiceCount > 0 ? '最高分' : '还没练过'),
                ],
              ),
            ),
          ),
          if (wholeSongScores(_history).length >= 2)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 14, 20, 0),
                child: ScoreTrend(history: _history),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 16, 20, 4),
              child: FilledButton.icon(
                onPressed: () => _practice(),
                icon: const Icon(Icons.mic_rounded),
                label: const Text('整首练习'),
              ),
            ),
          ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Text('点任意一句，单独循环练这一句。', style: context.type.bodySmall),
            ),
          ),
          SliverList.builder(
            itemCount: ref.lines.length,
            itemBuilder: (context, i) {
              final line = ref.lines[i];
              final score = lastLineScores[line.index];
              final trend = lineScores(_history, line.index);
              final missing = line.tokens.where((t) => t.notes.isEmpty).length;
              return InkWell(
                onTap: () => _practice(line: line.index),
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(20, 14, 20, 10),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          SizedBox(
                            width: 44,
                            child: Padding(
                              padding: const EdgeInsets.only(top: 4),
                              child: Text(clock(line.start),
                                  style: context.type.labelSmall?.copyWith(fontFeatures: tabular)),
                            ),
                          ),
                          Expanded(child: Text(line.text, style: lyricsStyle(context.type.titleMedium, ref.language))),
                          if (trend.length >= 2)
                            Padding(
                              padding: const EdgeInsets.only(right: 10, top: 2),
                              child: LineScoreSparkline(scores: trend),
                            ),
                          if (score != null) ScoreNumeral(score: score, size: 20),
                        ],
                      ),
                      if (missing > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 44, top: 2),
                          child: Text('$missing 个${ref.language.unit}没测到原唱音高',
                              style: context.type.labelSmall?.copyWith(color: p.gamboge)),
                        ),
                      const SizedBox(height: 6),
                      LinePitchGraph(reference: ref, line: line, contour: _track, height: 84),
                    ],
                  ),
                ),
              );
            },
          ),
          const SliverToBoxAdapter(child: SizedBox(height: 48)),
        ],
      ),
    );
  }
}
