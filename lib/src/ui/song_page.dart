import 'dart:async';

import 'package:flutter/material.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../import/import_pipeline.dart';
import '../library/recording.dart';
import '../library/song.dart';
import '../models/model_catalog.dart';
import '../separation/tensor_model.dart';
import 'export_page.dart';
import 'import_page.dart' show lyricsHint;
import 'lyrics_style.dart';
import 'model_setup.dart';
import 'pitch_editor_page.dart';
import 'pitch_graph.dart';
import 'practice_page.dart';
import 'score_trend.dart';
import 'song_share.dart';
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
  List<Recording> _recordings = const [];
  String? _error;
  AppServices? _services;
  int _referenceRevision = 0;
  bool _correcting = false;
  bool _realigning = false;
  bool _cancelAlignment = false;
  bool _savingAlignment = false;
  int _aligned = 0, _total = 0;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final services = AppScope.of(context);
    if (!identical(_services, services)) {
      _services?.pitchCorrections.removeListener(_correctionsChanged);
      _services = services;
      _referenceRevision = services.pitchCorrections.savedRevisionFor(widget.songId);
      _correcting = services.pitchCorrections.busyFor(widget.songId);
      services.pitchCorrections.addListener(_correctionsChanged);
      unawaited(_load());
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _showCorrectionFailure();
      });
    }
  }

  @override
  void dispose() {
    _services?.pitchCorrections.removeListener(_correctionsChanged);
    super.dispose();
  }

  void _correctionsChanged() {
    final corrections = _services!.pitchCorrections;
    final busy = corrections.busyFor(widget.songId);
    if (_correcting != busy) setState(() => _correcting = busy);
    final revision = corrections.savedRevisionFor(widget.songId);
    if (revision != _referenceRevision) {
      _referenceRevision = revision;
      unawaited(_refreshReference(revision));
    }
    _showCorrectionFailure();
  }

  void _showCorrectionFailure() {
    final message = _services!.pitchCorrections.takeBackgroundFailure(widget.songId);
    if (message != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(message)));
    }
  }

  Future<void> _refreshReference(int revision) async {
    final services = _services!;
    try {
      final ref = await services.songs.loadReference(widget.songId);
      if (mounted && identical(_services, services) && revision == _referenceRevision) {
        setState(() => _ref = ref);
      }
    } catch (e) {
      if (mounted && identical(_services, services) && revision == _referenceRevision) {
        setState(() => _error = '$e');
      }
    }
  }

  Future<void> _load() async {
    if (!mounted) return;
    final services = _services!;
    final repo = services.songs;
    final revision = _referenceRevision;
    try {
      final ref = await repo.loadReference(widget.songId);
      final track = await repo.loadPitchTrack(widget.songId);
      final history = await repo.loadHistory(widget.songId);
      final recordings = await repo.loadRecordings(widget.songId);
      final meta = await repo.load(widget.songId);
      if (!mounted || !identical(_services, services)) return;
      setState(() {
        _meta = meta;
        if (revision == _referenceRevision || _ref == null) _ref = ref;
        _track = track;
        _history = history;
        _recordings = recordings;
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  Future<void> _practice({int? line}) async {
    Future<void>? saved;
    final meta = _meta!, ref = _ref!, contour = _track;
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => PracticePage(
        meta: meta,
        reference: ref,
        contour: contour,
        loopLine: line,
        onLeave: (f) => saved = f,
      ),
    ));
    // What was just sung is in the history before it is read again.
    await saved;
    await _load();
  }

  Future<void> _openRecording(Recording r) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(
      builder: (_) => ExportPage(songId: widget.songId, recordingId: r.id),
    ));
    await _load();
  }

  Future<void> _correct(int line) => Navigator.of(context).push(MaterialPageRoute<void>(
    builder: (_) => PitchEditorPage(songId: widget.songId, line: line),
  ));

  Future<void> _rename() async {
    final current = _meta!.title;
    var input = current;
    final form = GlobalKey<FormState>();
    final title = await showDialog<String>(
      context: context,
      builder: (ctx) {
        void submit() {
          if (form.currentState!.validate()) Navigator.pop(ctx, input.trim());
        }

        return AlertDialog(
          title: const Text('修改歌名'),
          content: Form(
            key: form,
            child: TextFormField(
              initialValue: current,
              autofocus: true,
              textInputAction: TextInputAction.done,
              decoration: const InputDecoration(labelText: '歌名'),
              validator: (value) => (value?.trim().isEmpty ?? true) ? '请输入歌名' : null,
              onChanged: (value) => input = value,
              onFieldSubmitted: (_) => submit(),
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
            FilledButton(onPressed: submit, child: const Text('保存')),
          ],
        );
      },
    );
    if (!mounted || title == null || title == current) return;
    try {
      final meta = await AppScope.of(context).songs.rename(widget.songId, title);
      if (mounted) setState(() => _meta = meta);
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('歌名保存失败：$e')));
    }
  }

  Future<void> _editLyrics() async {
    final services = _services!;
    if (services.pitchCorrections.busyFor(widget.songId)) return;
    var lyrics = _meta!.lyrics;
    final edited = await showModalBottomSheet<String>(
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
              'HuBERTFA 会用已保存的人声重新测原唱音高、重新对齐每句歌词。'
              '${_ref!.corrected ? '没改动的句子里，你校正过的位置和音高会保留。' : ''}',
              style: ctx.type.bodySmall,
            ),
            const SizedBox(height: 14),
            TextFormField(
              initialValue: lyrics,
              onChanged: (text) => lyrics = text,
              minLines: 8,
              maxLines: 14,
              decoration: const InputDecoration(hintText: lyricsHint),
            ),
            const SizedBox(height: 14),
            FilledButton(onPressed: () => Navigator.pop(ctx, lyrics), child: const Text('重新对齐')),
          ],
        ),
      ),
    );
    if (edited == null || !mounted) return;
    if (!await ensureModels(context, requiredModels: [hubertFaModel]) || !mounted) return;
    if (services.pitchCorrections.busyFor(widget.songId)) return;
    setState(() {
      _realigning = true;
      _cancelAlignment = false;
      _savingAlignment = false;
      _aligned = _total = 0;
    });
    final awake = ScreenAwake()..hold();
    try {
      await realignSong(
        services.songs, widget.songId, edited, hubertFaPath: services.models.pathFor(hubertFaModel)!,
        pitchModelPath: services.activePitchModel,
        onProgress: (done, total) {
          if (!mounted) return;
          setState(() {
            _aligned = done;
            _total = total;
          });
        },
        isCancelled: () => !mounted || _cancelAlignment,
        onSaving: () => setState(() => _savingAlignment = true),
      );
      if (mounted) await _load();
    } on SeparationCancelled {
      // The worker closes its session before returning here.
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e')));
    } finally {
      awake.release();
      if (mounted) setState(() => _realigning = false);
    }
  }

  Future<void> _delete() async {
    final services = _services!;
    if (services.pitchCorrections.busyFor(widget.songId)) return;
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
    if (ok != true || !mounted || services.pitchCorrections.busyFor(widget.songId)) return;
    await services.songs.delete(widget.songId);
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
    if (_realigning) {
      return PopScope(
        canPop: !_savingAlignment,
        onPopInvokedWithResult: (didPop, _) {
          if (didPop) _cancelAlignment = true;
        },
        child: Scaffold(
          appBar: AppBar(title: Text(meta.title), automaticallyImplyLeading: !_savingAlignment),
          body: Center(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                CircularProgressIndicator(value: _total == 0 ? null : _aligned / _total),
                const SizedBox(height: 16),
                Text(_savingAlignment ? '正在保存…' : _total == 0 ? '正在准备对齐…' : '已对齐 $_aligned / $_total 句'),
                if (!_savingAlignment)
                  TextButton(
                    onPressed: _cancelAlignment ? null : () => setState(() => _cancelAlignment = true),
                    child: Text(_cancelAlignment ? '正在取消…' : '取消'),
                  ),
              ],
            ),
          ),
        ),
      );
    }
    final lastLineScores = <int, ScoreInKey>{
      for (final r in _history)
        for (final e in r.lineScores.entries) e.key: (score: e.value, transpose: r.transpose),
    };
    // The lines sung least well the last time, worst first.
    final weak = [
      for (final line in ref.lines)
        if (lastLineScores[line.index] case final s? when s.score < 80) (line, s),
    ]..sort((a, b) => a.$2.score.compareTo(b.$2.score));
    final p = context.yt;
    return Scaffold(
      // Always at hand, however far down the lines go.
      bottomNavigationBar: SafeArea(
        minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
        child: FilledButton.icon(
          onPressed: () => _practice(),
          icon: const Icon(Icons.mic_rounded),
          label: const Text('整首练习'),
        ),
      ),
      body: CustomScrollView(
        slivers: [
          SliverAppBar.large(
            title: Text(meta.title),
            actions: [
              PopupMenuButton<String>(
                icon: const Icon(Icons.more_horiz_rounded),
                onSelected: (v) => switch (v) {
                  'rename' => _rename(),
                  'edit' => _editLyrics(),
                  'pitch' => _correct(0),
                  'share' => showSongShare(context, meta),
                  _ => _delete(),
                },
                itemBuilder: (_) => [
                  const PopupMenuItem(value: 'rename', child: Text('修改歌名')),
                  const PopupMenuItem(value: 'pitch', child: Text('校正位置和音高')),
                  PopupMenuItem(value: 'edit', enabled: !_correcting, child: const Text('修改歌词')),
                  const PopupMenuItem(value: 'share', child: Text('发给别人')),
                  PopupMenuItem(value: 'delete', enabled: !_correcting, child: const Text('删除这首歌')),
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
                  ScoreNumeral(
                    score: meta.bestScore,
                    size: 34,
                    // The best score is of runs through the whole song.
                    label: meta.bestScore != null
                        ? '最高分${transposeSuffix(meta.bestScoreTranspose)}'
                        : (meta.practiceCount > 0 ? '还没唱完过整首' : '还没练过'),
                  ),
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
          if (weak.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text('先练这几句', style: context.type.titleLarge),
                    const SizedBox(height: 2),
                    Text('上次唱得最不准的几句，点一下单独循环练。', style: context.type.bodySmall),
                    const SizedBox(height: 10),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: [
                        for (final (line, score) in weak.take(3))
                          ActionChip(
                            avatar: Icon(Icons.repeat_one_rounded, size: 18, color: p.ink),
                            label: Text(
                              '${_excerpt(line.text)}  ${score.score.round()} 分${transposeSuffix(score.transpose)}',
                              style: lyricsStyle(context.type.bodyMedium?.copyWith(color: p.ink), ref.language),
                            ),
                            onPressed: () => _practice(line: line.index),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          if (_recordings.isNotEmpty)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(20, 22, 20, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Text('我的录音', style: context.type.titleLarge),
                    const SizedBox(height: 2),
                    Text('点一段，配上伴奏做成成品导出。', style: context.type.bodySmall),
                    for (final r in _recordings)
                      ListTile(
                        contentPadding: EdgeInsets.zero,
                        leading: const Icon(Icons.library_music_rounded),
                        title: Text(_recordingTitle(r)),
                        subtitle: Text(
                          '从 ${clock(r.start)} 起，${clock(r.duration)}'
                          '${transposeSuffix(r.transpose)}${r.score == null ? '' : '，${r.score!.round()} 分'}',
                          style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
                        ),
                        trailing: Icon(Icons.chevron_right_rounded, color: p.inkFaint),
                        onTap: () => _openRecording(r),
                      ),
                  ],
                ),
              ),
            ),
          SliverToBoxAdapter(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 10, 20, 12),
              child: Text('点任意一句，单独循环练这一句。哪个${ref.language.unit}的位置或目标音不对，点那一句右边的笔校正。',
                  style: context.type.bodySmall),
            ),
          ),
          SliverList.builder(
            itemCount: ref.lines.length,
            itemBuilder: (context, i) {
              final line = ref.lines[i];
              final score = lastLineScores[line.index];
              final trend = recentScores(_history, line: line.index, last: 10);
              final missing = line.tokens.where((t) => t.notes.isEmpty).length;
              final corrected = line.tokens.where((t) => t.corrected).length;
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
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(line.text, style: lyricsStyle(context.type.titleMedium, ref.language)),
                                if (line.translation case final translation?)
                                  Padding(
                                    padding: const EdgeInsets.only(top: 2),
                                    child: Text(translation, style: context.type.bodySmall),
                                  ),
                              ],
                            ),
                          ),
                          if (trend.length >= 2)
                            Padding(
                              padding: const EdgeInsets.only(right: 10, top: 2),
                              child: LineScoreSparkline(
                                scores: [for (final s in trend) s.score],
                                transposes: [for (final s in trend) s.transpose],
                              ),
                            ),
                          if (score != null)
                            ScoreNumeral(
                              score: score.score,
                              size: 20,
                              label: score.transpose == 0 ? null : transposeMark(score.transpose),
                            ),
                          IconButton(
                            tooltip: '校正这一句',
                            visualDensity: VisualDensity.compact,
                            icon: Icon(Icons.edit_rounded, size: 19, color: p.inkSoft),
                            onPressed: () => _correct(line.index),
                          ),
                        ],
                      ),
                      if (corrected > 0)
                        Padding(
                          padding: const EdgeInsets.only(left: 44, top: 2),
                          child: Text('校正过 $corrected 个${ref.language.unit}', style: context.type.labelSmall),
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

/// The start of a lyric line, short enough for a chip.
String _excerpt(String text, {int length = 7}) {
  final chars = text.characters;
  return chars.length <= length ? text : '${chars.take(length)}…';
}

String _recordingTitle(Recording r) {
  final t = r.createdAt;
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month} 月 ${t.day} 日 ${two(t.hour)}:${two(t.minute)}';
}
