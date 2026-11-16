import 'package:flutter/material.dart';

import '../app/services.dart';
import '../library/song.dart';
import '../models/model_catalog.dart';
import '../models/model_manager.dart';
import 'import_page.dart';
import 'model_setup.dart';
import 'pitch_graph.dart';
import 'settings_page.dart';
import 'song_page.dart';
import 'theme.dart';
import 'tuner_page.dart';
import 'widgets.dart';

/// Home screen: the songs saved on this device, each with its melody drawn
/// as a single ink line.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<SongMeta>? _songs;
  bool _loaded = false;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (!_loaded) {
      _loaded = true;
      _reload();
    }
  }

  Future<void> _reload() async {
    final songs = await AppScope.of(context).songs.list();
    if (mounted) setState(() => _songs = songs);
  }

  Future<void> _open(Widget page) async {
    await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => page));
    await _reload();
  }

  @override
  Widget build(BuildContext context) {
    final services = AppScope.of(context);
    final songs = _songs;
    final p = context.yt;
    return Scaffold(
      body: RefreshIndicator(
        onRefresh: _reload,
        color: p.ink,
        child: CustomScrollView(
          slivers: [
            SliverAppBar.large(
              title: const Text('曲库'),
              actions: [
                IconButton(
                  tooltip: '自由练习',
                  icon: const Icon(Icons.graphic_eq_rounded),
                  onPressed: () => _open(const TunerPage()),
                ),
                IconButton(
                  tooltip: '设置',
                  icon: const Icon(Icons.tune_rounded),
                  onPressed: () => _open(const SettingsPage()),
                ),
                const SizedBox(width: 8),
              ],
            ),
            SliverToBoxAdapter(
              child: ListenableBuilder(
                listenable: services.models,
                builder: (context, _) => _ModelNotice(models: services.models),
              ),
            ),
            if (songs != null && songs.isEmpty)
              SliverFillRemaining(
                hasScrollBody: false,
                child: _EmptyLibrary(onImport: () => _open(const ImportPage())),
              ),
            if (songs != null && songs.isNotEmpty)
              SliverList.separated(
                itemCount: songs.length,
                separatorBuilder: (_, _) => const Divider(indent: 20, endIndent: 20),
                itemBuilder: (context, i) =>
                    _SongRow(song: songs[i], onTap: () => _open(SongPage(songId: songs[i].id))),
              ),
            const SliverToBoxAdapter(child: SizedBox(height: 120)),
          ],
        ),
      ),
      bottomNavigationBar: songs == null || songs.isEmpty
          ? null
          : SafeArea(
              minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
              child: FilledButton.icon(
                onPressed: () => _open(const ImportPage()),
                icon: const Icon(Icons.add_rounded),
                label: const Text('导入歌曲'),
              ),
            ),
    );
  }
}

/// Says that the vocal model still has to be downloaded (or is on its way).
/// Hidden once it is installed: the harmony model is downloaded the first
/// time an import asks for it.
class _ModelNotice extends StatelessWidget {
  const _ModelNotice({required this.models});
  final ModelManager models;

  @override
  Widget build(BuildContext context) {
    if (models.isInstalled(vocalModel)) return const SizedBox.shrink();
    final p = context.yt;
    final String text;
    final String action;
    if (models.busy) {
      text = models.phase == ModelPhase.downloading
          ? '正在下载分离模型，${(models.progress * 100).floor()}%'
          : '正在准备分离模型…';
      action = '查看';
    } else {
      text = '导入整首歌之前，要先下载人声分离模型（${formatMegabytes(vocalModel.bytes)}）。去和声模型仅在打开“去和声”时需要。'
          '已经分离好的纯人声可以直接导入。';
      action = '下载';
    }
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
      child: Container(
        padding: const EdgeInsets.fromLTRB(16, 14, 8, 14),
        decoration: BoxDecoration(
          color: p.surface,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: p.hairline),
        ),
        child: Row(
          children: [
            Container(width: 3, height: 38, decoration: BoxDecoration(color: p.gamboge, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 12),
            Expanded(child: Text(text, style: context.type.bodySmall?.copyWith(fontFeatures: tabular))),
            TextButton(onPressed: () => ensureModels(context, requiredModels: const [vocalModel]), child: Text(action)),
          ],
        ),
      ),
    );
  }
}

class _EmptyLibrary extends StatelessWidget {
  const _EmptyLibrary({required this.onImport});
  final VoidCallback onImport;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 24, 28, 40),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text('从第一首歌开始', style: context.type.headlineMedium),
          const SizedBox(height: 12),
          Text('选一首想练的歌，贴上带时间的歌词。YinTrace 会分离出原唱人声，'
              '把每个字的音高画出来，你唱的时候就能看到自己哪里高了、哪里低了。',
              style: context.type.bodyMedium),
          const SizedBox(height: 28),
          FilledButton.icon(
            onPressed: onImport,
            icon: const Icon(Icons.add_rounded),
            label: const Text('导入歌曲'),
          ),
        ],
      ),
    );
  }
}

class _SongRow extends StatelessWidget {
  const _SongRow({required this.song, required this.onTap});
  final SongMeta song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final repo = AppScope.of(context).songs;
    final facts = <String>[
      clock(song.duration),
      if (song.practiceCount > 0) '练过 ${song.practiceCount} 次' else '还没练过',
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 16, 20, 16),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.titleMedium),
                  if (song.artist.isNotEmpty)
                    Padding(
                      padding: const EdgeInsets.only(top: 2),
                      child: Text(song.artist, style: context.type.bodySmall),
                    ),
                  const SizedBox(height: 10),
                  FutureBuilder<List<(double, double, double)>>(
                    future: repo.loadMelody(song.id),
                    builder: (context, snap) => MelodyFingerprint(notes: snap.data ?? const []),
                  ),
                  const SizedBox(height: 8),
                  Text(facts.join('，'), style: context.type.labelSmall?.copyWith(fontFeatures: tabular)),
                ],
              ),
            ),
            if (song.bestScore != null) ...[
              const SizedBox(width: 20),
              ScoreNumeral(score: song.bestScore, label: '最高分'),
            ],
          ],
        ),
      ),
    );
  }
}
