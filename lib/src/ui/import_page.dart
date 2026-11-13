import 'dart:async';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';

import '../analysis/lrc.dart';
import '../app/model_store.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../import/import_job.dart';
import '../import/import_pipeline.dart';
import 'song_page.dart';

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
    final mdx = services.models.pathFor(ModelKind.mdx);
    final vr = services.models.pathFor(ModelKind.vr);
    if (_audioPath == null) return;
    if (!_vocalsOnly && mdx == null) {
      setState(() => _error = '缺少 UVR-MDX-NET-Voc_FT 模型，请先到“设置 → 模型”导入。');
      return;
    }
    final request = ImportRequest(
      audioPath: _audioPath!,
      lyrics: _lyrics.text,
      title: _title.text,
      artist: _artist.text,
      vocalsOnly: _vocalsOnly,
      accompanimentPath: _vocalsOnly ? _accPath : null,
      mdxModelPath: _vocalsOnly ? null : mdx,
      vrModelPath: _vocalsOnly || _skipHarmony ? null : vr,
      useCoreML: services.settings.useCoreML,
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
    final services = AppScope.of(context);
    final busy = _progress != null;
    final parsed = _parsed;
    final hasVr = services.models.pathFor(ModelKind.vr) != null;
    final canStart = !busy && _audioPath != null && parsed.lines.isNotEmpty;
    return PopScope(
      canPop: !busy,
      child: Scaffold(
        appBar: AppBar(title: const Text('导入歌曲')),
        body: busy ? _buildProgress(context) : _buildForm(context, parsed, hasVr),
        bottomNavigationBar: busy
            ? null
            : SafeArea(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
                  child: FilledButton.icon(
                    onPressed: canStart ? _start : null,
                    icon: const Icon(Icons.auto_awesome),
                    label: Text(_vocalsOnly ? '生成逐字音高图' : '分离人声并生成音高图'),
                  ),
                ),
              ),
      ),
    );
  }

  Widget _buildForm(BuildContext context, LrcParseResult parsed, bool hasVr) {
    final theme = Theme.of(context);
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        if (_error != null)
          Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: Text(_error!, style: TextStyle(color: theme.colorScheme.error)),
          ),
        Text('1. 选择音频', style: theme.textTheme.titleMedium),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _pickAudio(),
          icon: const Icon(Icons.audio_file_outlined),
          label: Text(_audioName ?? '选择歌曲文件（mp3 / m4a / wav / flac）'),
        ),
        SwitchListTile(
          contentPadding: EdgeInsets.zero,
          value: _vocalsOnly,
          onChanged: (v) => setState(() => _vocalsOnly = v),
          title: const Text('这已经是分离好的纯人声'),
          subtitle: const Text('跳过人声分离，直接测量音高'),
        ),
        if (_vocalsOnly)
          OutlinedButton.icon(
            onPressed: () => _pickAudio(accompaniment: true),
            icon: const Icon(Icons.library_music_outlined),
            label: Text(_accName ?? '（可选）选择伴奏，用于练习时播放'),
          ),
        if (!_vocalsOnly)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            value: _skipHarmony || !hasVr,
            onChanged: hasVr ? (v) => setState(() => _skipHarmony = v) : null,
            title: const Text('跳过去和声（6_HP-Karaoke）'),
            subtitle: Text(hasVr ? '歌曲没有和声时可以更快' : '未导入 6_HP-Karaoke 模型，将只做人声分离'),
          ),
        const SizedBox(height: 16),
        Text('2. 歌曲信息', style: theme.textTheme.titleMedium),
        TextField(controller: _title, decoration: const InputDecoration(labelText: '歌名')),
        TextField(controller: _artist, decoration: const InputDecoration(labelText: '歌手（可选）')),
        const SizedBox(height: 16),
        Text('3. 带时间的歌词', style: theme.textTheme.titleMedium),
        const SizedBox(height: 4),
        Text('每行格式为 [分:秒.百分秒]歌词，时间是这句开始唱的时刻；空格表示停顿。',
            style: theme.textTheme.bodySmall),
        const SizedBox(height: 8),
        TextField(
          controller: _lyrics,
          minLines: 8,
          maxLines: 18,
          keyboardType: TextInputType.multiline,
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            hintText: lyricsHint,
          ),
        ),
        const SizedBox(height: 8),
        if (_lyrics.text.trim().isNotEmpty)
          Text(
            parsed.lines.isEmpty
                ? '没有识别到带时间的歌词'
                : '识别到 ${parsed.lines.length} 句、${parsed.lines.fold<int>(0, (s, l) => s + l.tokens.length)} 个字'
                    '${parsed.errors.isEmpty ? '' : '；${parsed.errors.length} 行无法识别：${parsed.errors.first}'}',
            style: TextStyle(color: parsed.lines.isEmpty ? theme.colorScheme.error : theme.colorScheme.primary),
          ),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildProgress(BuildContext context) {
    final p = _progress!;
    final theme = Theme.of(context);
    final elapsed = _stopwatch.elapsed.inSeconds;
    String eta = '';
    if (p.overall > 0.03 && elapsed > 5) {
      final remain = (elapsed / p.overall * (1 - p.overall)).round();
      eta = '，预计还需 ${remain ~/ 60} 分 ${remain % 60} 秒';
    }
    return Padding(
      padding: const EdgeInsets.all(24),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Text(p.stage.label, style: theme.textTheme.titleLarge),
          const SizedBox(height: 20),
          LinearProgressIndicator(value: p.overall, minHeight: 8),
          const SizedBox(height: 12),
          Text('${(p.overall * 100).toStringAsFixed(1)}%  · 已用 ${elapsed ~/ 60} 分 ${elapsed % 60} 秒$eta'),
          const SizedBox(height: 24),
          const Text('人声分离在手机上完成，可能需要几分钟。\n请保持应用在前台、屏幕常亮。', textAlign: TextAlign.center),
          const SizedBox(height: 24),
          OutlinedButton(onPressed: _cancel, child: const Text('取消')),
        ],
      ),
    );
  }
}
