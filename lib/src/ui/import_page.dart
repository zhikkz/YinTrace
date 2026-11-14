import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../analysis/lrc.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../import/import_job.dart';
import '../import/import_pipeline.dart';
import '../models/model_catalog.dart';
import 'model_setup.dart';
import 'song_page.dart';
import 'theme.dart';

const audioExtensions = ['mp3', 'm4a', 'aac', 'wav', 'flac', 'aif', 'aiff', 'caf', 'alac', 'mp4'];

const lyricsHint = '[00:12.40]夜里的风慢慢吹过窗台\n[00:17.95]远处的灯一盏一盏亮开\n[00:35.80]下雨了 记得带伞';

/// Import a song: audio file + timed lyrics -> separated vocal, per
/// character pitch map, stored locally.
class ImportPage extends StatefulWidget {
  const ImportPage({super.key});

  @override
  State<ImportPage> createState() => _ImportPageState();
}

class _ImportPageState extends State<ImportPage> {
  final _title = TextEditingController();
  final _artist = TextEditingController();
  final _lyrics = TextEditingController();
  String? _audioPath;
  String? _audioName;
  String? _accPath;
  String? _accName;
  bool _vocalsOnly = false;
  bool _skipHarmony = false;

  ImportJob? _job;
  StreamSubscription<ImportEvent>? _sub;
  ImportProgress? _progress;
  String? _error;
  final _stopwatch = Stopwatch();

  @override
  void initState() {
    super.initState();
    _lyrics.addListener(() => setState(() {}));
  }

  @override
  void dispose() {
    _sub?.cancel();
    _job?.cancel();
    keepScreenOn(false);
    _title.dispose();
    _artist.dispose();
    _lyrics.dispose();
    super.dispose();
  }

  Future<void> _pickAudio({bool accompaniment = false}) async {
    final f = await FilePicker.pickFile(type: FileType.custom, allowedExtensions: audioExtensions);
    final path = f?.path;
    if (f == null || path == null) return;
    setState(() {
      if (accompaniment) {
        _accPath = path;
        _accName = f.name;
      } else {
        _audioPath = path;
        _audioName = f.name;
        if (_title.text.isEmpty) {
          final dot = f.name.lastIndexOf('.');
          _title.text = dot > 0 ? f.name.substring(0, dot) : f.name;
        }
      }
    });
  }

  LrcParseResult get _parsed => parseLrc(_lyrics.text);

  Future<void> _start() async {
    final services = AppScope.of(context);
    if (_audioPath == null) return;
    // Separating a whole song needs the two models; offer to download them.
    if (!_vocalsOnly && !await ensureModels(context)) return;
    if (!mounted) return;
    final mdx = services.models.pathFor(vocalModel);
    final vr = services.models.pathFor(karaokeModel);
    final request = ImportRequest(
      audioPath: _audioPath!,
      lyrics: _lyrics.text,
      title: _title.text,
      artist: _artist.text,
      vocalsOnly: _vocalsOnly,
      accompanimentPath: _vocalsOnly ? _accPath : null,
      mdxModelPath: _vocalsOnly ? null : mdx,
      vrModelPath: _vocalsOnly || _skipHarmony ? null : vr,
    );
    setState(() {
      _error = null;
      _progress = const ImportProgress(ImportStage.decoding, 0, 0);
    });
    await keepScreenOn(true);
    _stopwatch
      ..reset()
      ..start();
    final job = await ImportJob.start(request, services.songs.root.path);
    _job = job;
    _sub = job.events.listen((e) async {
      switch (e) {
        case ImportProgressEvent(:final progress):
          if (mounted) setState(() => _progress = progress);
        case ImportDoneEvent(:final song):
          _finish();
          if (!mounted) return;
          await Navigator.of(context)
              .pushReplacement(MaterialPageRoute<void>(builder: (_) => SongPage(songId: song.id)));
        case ImportFailedEvent(:final message, :final cancelled):
          _finish();
          if (mounted) {
            setState(() {
              _progress = null;
              _error = cancelled ? null : '处理失败：$message';
            });
          }
      }
    });
  }

  void _finish() {
    _stopwatch.stop();
    keepScreenOn(false);
    _job = null;
  }

  Future<void> _cancel() async {
    await _job?.cancel();
  }

  @override
  Widget build(BuildContext context) {
    final busy = _progress != null;
    final parsed = _parsed;
    final canStart = !busy && _audioPath != null && parsed.lines.isNotEmpty;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: Text(busy ? '' : '导入歌曲')),
        body: busy ? _buildProgress(context) : _buildForm(context, parsed),
        bottomNavigationBar: busy
            ? null
            : SafeArea(
                minimum: const EdgeInsets.fromLTRB(20, 8, 20, 12),
                child: FilledButton(
                  onPressed: canStart ? _start : null,
                  child: Text(_vocalsOnly ? '生成逐字音高图' : '分离人声，生成音高图'),
                ),
              ),
      ),
    );
  }

  Widget _step(BuildContext context, int n, String title, {String? hint}) {
    final p = context.yt;
    return Padding(
      padding: const EdgeInsets.only(top: 28, bottom: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              shape: BoxShape.circle,
              border: Border.all(color: p.ink, width: 1.3),
            ),
            child: Text(
              '$n',
              style: context.type.labelMedium?.copyWith(color: p.ink, fontWeight: FontWeight.w700),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(title, style: context.type.titleLarge),
                if (hint != null) ...[const SizedBox(height: 4), Text(hint, style: context.type.bodySmall)],
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _picker(
    BuildContext context, {
    required String? picked,
    required String empty,
    required VoidCallback onTap,
  }) {
    final p = context.yt;
    return OutlinedButton(
      onPressed: onTap,
      child: Row(
        children: [
          Icon(
            picked == null ? Icons.add_rounded : Icons.music_note_rounded,
            color: picked == null ? p.inkSoft : p.ink,
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(
              picked ?? empty,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.bodyLarge?.copyWith(color: picked == null ? p.inkSoft : p.ink),
            ),
          ),
          if (picked != null) Text('更换', style: context.type.labelMedium),
        ],
      ),
    );
  }

  Widget _buildForm(BuildContext context, LrcParseResult parsed) {
    final p = context.yt;
    final chars = parsed.lines.fold<int>(0, (s, l) => s + l.tokens.length);
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 24),
      children: [
        if (_error != null)
          Container(
            margin: const EdgeInsets.only(top: 8),
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.cinnabar.withValues(alpha: 0.08),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Text(_error!, style: context.type.bodyMedium?.copyWith(color: p.cinnabar)),
          ),
        _step(context, 1, '选择音频'),
        _picker(context, picked: _audioName, empty: '整首歌，mp3、m4a、wav 或 flac', onTap: () => _pickAudio()),
        const SizedBox(height: 6),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _vocalsOnly,
          onChanged: (v) => setState(() => _vocalsOnly = v),
          title: const Text('这是已经分离好的纯人声'),
          subtitle: const Text('跳过人声分离，直接测音高'),
        ),
        if (_vocalsOnly)
          _picker(
            context,
            picked: _accName,
            empty: '伴奏（可选），练习时播放',
            onTap: () => _pickAudio(accompaniment: true),
          ),
        if (!_vocalsOnly)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _skipHarmony,
            onChanged: (v) => setState(() => _skipHarmony = v),
            title: const Text('不去和声'),
            subtitle: const Text('歌里没有和声时可以打开，处理更快'),
          ),
        _step(context, 2, '歌曲信息'),
        TextField(
          controller: _title,
          decoration: const InputDecoration(hintText: '歌名'),
        ),
        const SizedBox(height: 10),
        TextField(
          controller: _artist,
          decoration: const InputDecoration(hintText: '歌手（可选）'),
        ),
        _step(context, 3, '带时间的歌词', hint: '每行写成 [分:秒.百分秒]歌词，时间是这句开始唱的时刻。空格表示停顿。'),
        TextField(
          controller: _lyrics,
          minLines: 9,
          maxLines: 20,
          keyboardType: TextInputType.multiline,
          style: context.type.bodyLarge?.copyWith(fontFeatures: tabular, height: 1.6),
          decoration: const InputDecoration(hintText: lyricsHint),
        ),
        const SizedBox(height: 10),
        if (_lyrics.text.trim().isNotEmpty)
          Row(
            children: [
              Icon(
                parsed.lines.isEmpty ? Icons.error_outline_rounded : Icons.check_rounded,
                size: 18,
                color: parsed.lines.isEmpty ? p.cinnabar : p.malachite,
              ),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  parsed.lines.isEmpty
                      ? '没有找到带时间的歌词'
                      : '${parsed.lines.length} 句，$chars 个字'
                            '${parsed.errors.isEmpty ? '' : '。有 ${parsed.errors.length} 行认不出：${parsed.errors.first}'}',
                  style: context.type.bodyMedium?.copyWith(color: parsed.lines.isEmpty ? p.cinnabar : p.ink),
                ),
              ),
            ],
          ),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    final pr = _progress!;
    final p = context.yt;
    final elapsed = _stopwatch.elapsed.inSeconds;
    final stages = ImportStage.values.where(
      (s) => _vocalsOnly ? !(s == ImportStage.separatingVocals || s == ImportStage.removingHarmony) : true,
    );
    return Padding(
      padding: const EdgeInsets.fromLTRB(28, 8, 28, 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${(pr.overall * 100).floor()}%',
            style: context.type.displayLarge?.copyWith(fontFeatures: tabular),
          ),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: pr.overall, minHeight: 4, borderRadius: BorderRadius.circular(2)),
          const SizedBox(height: 10),
          Text('已用 $elapsed 秒', style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
          const SizedBox(height: 28),
          for (final s in stages)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 7),
              child: Row(
                children: [
                  SizedBox(
                    width: 22,
                    child: s.index < pr.stage.index
                        ? Icon(Icons.check_rounded, size: 18, color: p.malachite)
                        : s == pr.stage
                        ? SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              value: pr.stageFraction > 0 ? pr.stageFraction : null,
                            ),
                          )
                        : Icon(Icons.circle, size: 6, color: p.staffStrong),
                  ),
                  const SizedBox(width: 10),
                  Text(
                    s.label,
                    style: context.type.bodyLarge?.copyWith(
                      color: s.index <= pr.stage.index ? p.ink : p.inkFaint,
                      fontWeight: s == pr.stage ? FontWeight.w600 : FontWeight.w400,
                    ),
                  ),
                ],
              ),
            ),
          const Spacer(),
          Text('处理时间取决于歌曲长度和设备性能。请让 YinTrace 保持在前台，屏幕会保持常亮。', style: context.type.bodySmall),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _cancel,
            style: OutlinedButton.styleFrom(alignment: Alignment.center),
            child: const Text('取消'),
          ),
        ],
      ),
    );
  }
}
