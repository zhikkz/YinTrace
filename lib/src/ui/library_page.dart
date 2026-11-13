import 'package:flutter/material.dart';

import '../app/model_store.dart';
import '../app/services.dart';
import '../library/song.dart';
import 'app.dart';
import 'import_page.dart';
import 'settings_page.dart';
import 'song_page.dart';
import 'tuner_page.dart';

/// Home screen: the songs saved on this device.
class LibraryPage extends StatefulWidget {
  const LibraryPage({super.key});

  @override
  State<LibraryPage> createState() => _LibraryPageState();
}

class _LibraryPageState extends State<LibraryPage> {
  List<SongMeta>? _songs;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _songs ??= const [];
    _reload();
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
    final songs = _songs ?? const [];
    final missingModels = services.models.pathFor(ModelKind.mdx) == null;
    return Scaffold(
      appBar: AppBar(
        title: const Text('YinTrace 唱歌练习'),
        actions: [
          IconButton(
            tooltip: '自由练习（调音器）',
            icon: const Icon(Icons.graphic_eq),
            onPressed: () => _open(const TunerPage()),
          ),
          IconButton(
            tooltip: '设置',
            icon: const Icon(Icons.settings_outlined),
            onPressed: () => _open(const SettingsPage()),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: () => _open(const ImportPage()),
        icon: const Icon(Icons.add),
        label: const Text('导入歌曲'),
      ),
      body: RefreshIndicator(
        onRefresh: _reload,
        child: ListView(
          padding: const EdgeInsets.only(bottom: 96, top: 8),
          children: [
            if (missingModels)
              Card(
                color: Theme.of(context).colorScheme.tertiaryContainer,
                child: ListTile(
                  leading: const Icon(Icons.info_outline),
                  title: const Text('还没有导入分离模型'),
                  subtitle: const Text('导入整首歌需要 UVR-MDX-NET-Voc_FT 与 6_HP-Karaoke（ONNX）。'
                      '已经分离好的纯人声可以直接导入。'),
                  onTap: () => _open(const SettingsPage()),
                ),
              ),
            if (songs.isEmpty)
              const Padding(
                padding: EdgeInsets.fromLTRB(32, 80, 32, 0),
                child: Column(
                  children: [
                    Icon(Icons.queue_music, size: 64),
                    SizedBox(height: 16),
                    Text('曲库是空的', style: TextStyle(fontSize: 18)),
                    SizedBox(height: 8),
                    Text('点“导入歌曲”，选择音频并粘贴带时间的歌词，\n生成逐字音高图后就可以开始练习。',
                        textAlign: TextAlign.center),
                  ],
                ),
              ),
            for (final s in songs) _SongTile(song: s, onTap: () => _open(SongPage(songId: s.id))),
          ],
        ),
      ),
    );
  }
}

class _SongTile extends StatelessWidget {
  const _SongTile({required this.song, required this.onTap});
  final SongMeta song;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final cs = Theme.of(context).colorScheme;
    final best = song.bestScore;
    return Card(
      child: ListTile(
        onTap: onTap,
        leading: CircleAvatar(
          backgroundColor: cs.primaryContainer,
          child: Text(song.title.isEmpty ? '?' : song.title.characters.first,
              style: TextStyle(color: cs.onPrimaryContainer)),
        ),
        title: Text(song.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([
          if (song.artist.isNotEmpty) song.artist,
          formatDuration(song.duration),
          if (song.practiceCount > 0) '练习 ${song.practiceCount} 次',
        ].join(' · ')),
        trailing: best == null
            ? const Icon(Icons.chevron_right)
            : Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  Text(formatScore(best),
                      style: Theme.of(context).textTheme.titleLarge?.copyWith(color: cs.primary)),
                  Text('最高分', style: Theme.of(context).textTheme.labelSmall),
                ],
              ),
      ),
    );
  }
}
