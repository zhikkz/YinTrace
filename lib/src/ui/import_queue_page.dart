import 'dart:async';

import 'package:flutter/material.dart';

import '../app/services.dart';
import '../import/import_pipeline.dart';
import '../import/import_queue.dart';
import 'import_page.dart';
import 'song_page.dart';
import 'theme.dart';
import 'widgets.dart';

class ImportQueuePage extends StatefulWidget {
  const ImportQueuePage({super.key});

  @override
  State<ImportQueuePage> createState() => _ImportQueuePageState();
}

class _ImportQueuePageState extends State<ImportQueuePage> {
  late ImportQueue _queue;
  late final Timer _ticker;

  @override
  void initState() {
    super.initState();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (_queue.activeCount > 0 && ModalRoute.isCurrentOf(context) == true) {
        setState(() {});
      }
    });
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _queue = AppScope.of(context).importQueue;
  }

  @override
  void dispose() {
    _ticker.cancel();
    super.dispose();
  }

  Future<void> _cancel(ImportQueueEntry entry) async {
    final queue = _queue;
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('取消导入？'),
        content: Text(
          entry.status == ImportQueueStatus.queued
              ? '这首歌将从待处理任务中移除。'
              : '下次导入这首歌时需要从头处理。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context, false),
            child: const Text('保留任务'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(context, true),
            child: Text('取消导入', style: TextStyle(color: context.yt.cinnabar)),
          ),
        ],
      ),
    );
    if (confirmed == true) await queue.cancel(entry);
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('导入队列')),
    body: ListenableBuilder(
      listenable: _queue,
      builder: (context, _) {
        final entries = _queue.entries;
        if (entries.isEmpty) {
          return Center(child: Text('还没有导入任务', style: context.type.bodyLarge));
        }
        return ListView(
          padding: const EdgeInsets.fromLTRB(20, 8, 20, 20),
          children: [
            if (_queue.activeCount > 0)
              Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: Text(
                  '可以返回曲库练歌，导入会在音迹内继续。',
                  style: context.type.bodyMedium,
                ),
              ),
            for (final entry in entries)
              _QueueCard(
                key: ValueKey(entry),
                entry: entry,
                onCancel: () => _cancel(entry),
              ),
          ],
        );
      },
    ),
    bottomNavigationBar: SafeArea(
      minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
      child: FilledButton.icon(
        onPressed: () => ImportPage.open(context),
        icon: const Icon(Icons.add_rounded),
        label: const Text('继续导入歌曲'),
      ),
    ),
  );
}

class _QueueCard extends StatelessWidget {
  const _QueueCard({super.key, required this.entry, required this.onCancel});

  final ImportQueueEntry entry;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final song = entry.song;
    final status = entry.status;
    final progress = entry.progress;
    final started = entry.startedAt;
    final (label, color) = switch (status) {
      ImportQueueStatus.queued => ('等待处理', p.inkSoft),
      ImportQueueStatus.running => ('处理中', p.ink),
      ImportQueueStatus.cancelling => ('正在取消', p.inkSoft),
      ImportQueueStatus.completed => ('已导入', p.malachite),
      ImportQueueStatus.failed => ('导入失败', p.cinnabar),
      ImportQueueStatus.cancelled => ('已取消', p.inkSoft),
    };
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(song?.title ?? entry.title, style: context.type.titleMedium),
          const SizedBox(height: 4),
          Text(label, style: context.type.labelLarge?.copyWith(color: color)),
          if (status == ImportQueueStatus.running) ...[
            const SizedBox(height: 10),
            LinearProgressIndicator(
              value: progress?.overall,
              minHeight: 4,
              borderRadius: BorderRadius.circular(2),
            ),
            if (progress != null) ...[
              const SizedBox(height: 8),
              Text(
                '${progress.stage.label} · ${(progress.overall * 100).floor()}%'
                '${progress.total == null ? '' : ' · ${progress.done ?? 0} / ${progress.total} ${progress.stage == ImportStage.aligning ? '句' : '段'}'}',
                style: context.type.bodyMedium?.copyWith(fontFeatures: tabular),
              ),
              Text(
                '${importRemainingText(progress.remaining)}'
                '${started == null ? '' : ' · 已用 ${clock(DateTime.now().difference(started).inSeconds.toDouble())}'}',
                style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
              ),
            ],
          ],
          if (entry.error case final error?
              when status == ImportQueueStatus.failed) ...[
            const SizedBox(height: 6),
            Text(
              error,
              style: context.type.bodySmall?.copyWith(color: p.cinnabar),
            ),
          ],
          if (entry.canCancel || song != null)
            Align(
              alignment: AlignmentDirectional.centerEnd,
              child: song != null
                  ? TextButton.icon(
                      onPressed: () => Navigator.of(context).push(
                        MaterialPageRoute<void>(
                          builder: (_) => SongPage(songId: song.id),
                        ),
                      ),
                      icon: const Icon(Icons.arrow_forward_rounded),
                      label: const Text('打开歌曲'),
                    )
                  : TextButton(onPressed: onCancel, child: const Text('取消任务')),
            ),
        ],
      ),
    );
  }
}
