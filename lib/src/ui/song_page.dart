import 'package:flutter/material.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/services.dart';
import '../import/import_pipeline.dart';
import '../library/song.dart';
import 'app.dart';
import 'import_page.dart' show lyricsHint;
import 'pitch_graph.dart';
import 'practice_page.dart';

/// Overview of one song: the per-character pitch map line by line, history
/// and the entry points to practice.
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
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改歌词并重新对齐'),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: controller,
            minLines: 8,
            maxLines: 16,
            decoration: const InputDecoration(border: OutlineInputBorder(), hintText: lyricsHint),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('重新对齐')),
        ],
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
        content: const Text('分离出的人声、伴奏、音高图和练习记录都会被删除。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('删除')),
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
      return Scaffold(appBar: AppBar(), body: Center(child: Text('无法打开：$_error')));
    }
    if (meta == null || ref == null) {
      return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    }
    final lastLineScores = <int, double>{};
    for (final r in _history) {
      lastLineScores.addAll(r.lineScores);
    }
    final theme = Theme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text(meta.title),
        actions: [
          PopupMenuButton<String>(
            onSelected: (v) => v == 'edit' ? _editLyrics() : _delete(),
            itemBuilder: (_) => const [
              PopupMenuItem(value: 'edit', child: Text('修改歌词 / 重新对齐')),
              PopupMenuItem(value: 'delete', child: Text('删除歌曲')),
            ],
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _practice(),
        icon: const Icon(Icons.mic),
        label: const Text('整首练习'),
      ),
      body: ListView.builder(
        padding: const EdgeInsets.only(bottom: 96),
        itemCount: ref.lines.length + 1,
        itemBuilder: (context, i) {
          if (i == 0) {
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text([
                    if (meta.artist.isNotEmpty) meta.artist,
                    formatDuration(meta.duration),
                    '${ref.lines.length} 句',
                    meta.separated ? '已分离人声' : '导入的纯人声',
                    if (meta.accompanimentFile == null) '无伴奏',
                  ].join(' · ')),
                  const SizedBox(height: 4),
                  Text('最高分 ${formatScore(meta.bestScore)}   上次 ${formatScore(meta.lastScore)}   练习 ${meta.practiceCount} 次',
                      style: theme.textTheme.bodySmall),
                  const SizedBox(height: 8),
                  Text('点任意一句可以单句循环练习。', style: theme.textTheme.bodySmall),
                ],
              ),
            );
          }
          final line = ref.lines[i - 1];
          final score = lastLineScores[line.index];
          final weak = line.tokens.where((t) => t.notes.isEmpty).length;
          return Card(
            clipBehavior: Clip.antiAlias,
            child: InkWell(
              onTap: () => _practice(line: line.index),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  ListTile(
                    dense: true,
                    title: Text(line.text, style: theme.textTheme.titleMedium),
                    subtitle: Text('${formatDuration(line.start)} – ${formatDuration(line.end)}'
                        '${weak > 0 ? ' · $weak 个字没测到音高' : ''}'),
                    trailing: score == null
                        ? const Icon(Icons.repeat)
                        : Text(formatScore(score),
                            style: theme.textTheme.titleMedium?.copyWith(
                                color: PitchGraphColors.of(context).score(score))),
                  ),
                  LinePitchGraph(reference: ref, line: line, contour: _track),
                ],
              ),
            ),
          );
        },
      ),
    );
  }
}
