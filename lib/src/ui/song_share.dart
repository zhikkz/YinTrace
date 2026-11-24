import 'dart:io';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/services.dart';
import '../library/song.dart';
import '../library/song_package.dart';
import 'copyright_notice.dart';
import 'theme.dart';

Future<void> showSongShare(BuildContext context, SongMeta song) => showModalBottomSheet<void>(
  context: context,
  isScrollControlled: true,
  builder: (_) => SongShareSheet(song: song),
);

/// Makes a song into one file for someone else (see `song_package.dart`):
/// written to the app's folder in the Files app and offered to the share
/// sheet.
class SongShareSheet extends StatefulWidget {
  const SongShareSheet({super.key, required this.song, this.background = true, this.outputDir, this.share});

  final SongMeta song;

  /// For tests.
  final bool background;
  final Directory? outputDir;
  final bool Function(String path)? share;

  @override
  State<SongShareSheet> createState() => _SongShareSheetState();
}

class _SongShareSheetState extends State<SongShareSheet> {
  bool _busy = false;
  bool _confirming = false;
  String? _exported;
  String? _notice;
  String? _error;

  String get _audio => songPackageAudioFiles(widget.song).map((file) => file.$1.label).join('、');

  Future<bool> _confirm(String action) async {
    if (_busy || _confirming) return false;
    _confirming = true;
    try {
      return await confirmCopyright(context, contents: '歌曲文件包含$_audio、歌词', action: action);
    } finally {
      _confirming = false;
    }
  }

  Future<void> _export() async {
    if (!await _confirm('确认并导出及分享') || !mounted) return;
    final root = AppScope.of(context).songs.root.path;
    setState(() {
      _busy = true;
      _error = null;
      _notice = null;
    });
    try {
      final dir = widget.outputDir ?? await getApplicationDocumentsDirectory();
      dir.createSync(recursive: true);
      // The newest export of a song replaces the one before.
      final path = '${dir.path}/${songPackageName(widget.song)}';
      if (widget.background) {
        await exportSongPackageInBackground(root, widget.song.id, path);
      } else {
        exportSongPackageSync(root, widget.song.id, path);
      }
      if (!mounted) return;
      setState(() {
        _busy = false;
        _exported = path;
      });
      _share(path);
    } catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e is SongPackageException ? e.message : '导出失败：$e';
      });
    }
  }

  void _share(String path) {
    final shared = (widget.share ?? NativeAudio.shareFile)(path);
    if (!shared) setState(() => _notice = '已保存到 $path');
  }

  Future<void> _shareAgain(String path) async {
    if (await _confirm('确认并分享') && mounted) _share(path);
  }

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final exported = _exported;
    return SafeArea(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(24, 4, 24, 16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('把这首歌发给别人', style: context.type.headlineSmall),
            const SizedBox(height: 8),
            Text(
              '导出成一个文件，发给也在用音迹的人。对方在“导入歌曲”里选这个文件，不用再分离人声就能练。',
              style: context.type.bodyMedium,
            ),
            const SizedBox(height: 8),
            Text(
              '文件里有$_audio、歌词，以及你校正过的位置和音高；'
              '不包含你的练习成绩和录音。',
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 18),
            if (_error != null) ...[
              Text(_error!, style: context.type.bodyMedium?.copyWith(color: p.cinnabar)),
              const SizedBox(height: 14),
            ],
            if (_busy) ...[
              const LinearProgressIndicator(),
              const SizedBox(height: 8),
              Text('正在导出…', style: context.type.bodySmall),
            ] else if (exported == null)
              FilledButton.icon(
                onPressed: _export,
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('导出歌曲文件'),
              )
            else ...[
              Text('已导出 ${exported.split('/').last}', style: context.type.bodyMedium),
              const SizedBox(height: 4),
              Text(
                _notice ?? '在「文件」App 的 我的 iPhone › 音迹里也能找到。',
                style: context.type.bodySmall,
              ),
              const SizedBox(height: 14),
              FilledButton.icon(
                onPressed: () => _shareAgain(exported),
                icon: const Icon(Icons.ios_share_rounded),
                label: const Text('分享或存到别处'),
              ),
            ],
          ],
        ),
      ),
    );
  }
}
