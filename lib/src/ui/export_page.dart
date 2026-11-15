import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/screen_awake.dart';
import '../app/services.dart';
import '../audio/audio_backend.dart';
import '../export/mixdown.dart';
import '../export/recordings.dart';
import '../library/recording.dart';
import '../library/song.dart';
import 'theme.dart';
import 'widgets.dart';

/// What the preview plays: the accompaniment, the voice and its reverb.
class PreviewAudio {
  PreviewAudio(this.accompaniment, this.voice, this.wet);

  /// Stereo, from song time 0 (null when the song has none).
  final Float32List? accompaniment;

  /// Mono.
  final Float32List voice;

  /// Stereo reverb of the voice.
  final Float32List wet;
}

PreviewAudio preparePreview(String voicePath, String? accompanimentPath) {
  const audio = NativeAudioBackend();
  final voice = audio.decode(voicePath, sampleRate: 44100, channels: 1).samples;
  final acc = accompanimentPath == null
      ? null
      : audio.decode(accompanimentPath, sampleRate: 44100, channels: 2).samples;
  return PreviewAudio(acc, voice, renderReverb(voice));
}

/// Top level, so the isolate's closure captures only the two paths.
Future<PreviewAudio> preparePreviewInBackground(String voicePath, String? accompanimentPath) =>
    Isolate.run(() => preparePreview(voicePath, accompanimentPath));

/// Turns a kept recording into a finished track: the singer's voice with a
/// little reverb over the accompaniment, previewed live, exported as m4a to
/// the app's folder in the Files app and offered to the share sheet.
class ExportPage extends StatefulWidget {
  const ExportPage({
    super.key,
    required this.songId,
    required this.recordingId,
    this.engineFactory,
    this.background = true,
    this.outputDir,
    this.share,
  });

  final String songId;
  final String recordingId;

  /// For tests.
  final PracticeEngine Function()? engineFactory;
  final bool background;
  final Directory? outputDir;
  final bool Function(String path)? share;

  @override
  State<ExportPage> createState() => _ExportPageState();
}

class _ExportPageState extends State<ExportPage> with WidgetsBindingObserver {
  SongMeta? _meta;
  Recording? _rec;
  String? _error;
  PracticeEngine? _engine;
  bool _deviceOn = false;
  bool _ready = false;
  Timer? _clock;
  double? _progress;
  String? _exported;
  bool _loaded = false;

  /// Held while the preview plays or an export runs: nobody touches the
  /// screen while listening to four minutes of song, and a locked phone
  /// stops the preview.
  final _awake = ScreenAwake();

  void _syncAwake() => _awake.held = (_engine?.isPlaying ?? false) || _progress != null;

  static const _acc = 0, _dry = 1, _wet = 2;
  static const _sr = 44100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _load();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _stopDevice();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _clock?.cancel();
    _awake.release();
    final e = _engine;
    _engine = null;
    if (e != null) {
      try {
        e.stop();
      } catch (_) {}
      e.dispose();
    }
    final rec = _rec;
    if (rec != null) unawaited(_songs.saveRecording(widget.songId, rec));
    super.dispose();
  }

  late final _songs = AppScope.of(context).songs;

  Future<void> _load() async {
    try {
      final meta = await _songs.load(widget.songId);
      final rec = (await _songs.loadRecordings(widget.songId))
          .firstWhere((r) => r.id == widget.recordingId, orElse: () => throw StateError('这段录音已经删除了'));
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _rec = rec;
      });
      final accFile = meta.accompanimentFile;
      final voicePath = _songs.recordingPath(widget.songId, rec);
      final accPath = accFile == null ? null : _songs.pathFor(widget.songId, accFile);
      final audio = widget.background
          ? await preparePreviewInBackground(voicePath, accPath)
          : preparePreview(voicePath, accPath);
      if (!mounted) return;
      final e = _engine = widget.engineFactory?.call() ?? PracticeEngine.create(mode: EngineMode.playback);
      if (audio.accompaniment != null) e.loadTrackPcm(_acc, audio.accompaniment!, 2);
      e.loadTrackPcm(_dry, audio.voice, 1);
      e.loadTrackPcm(_wet, audio.wet, 2);
      _applyMix();
      e.seek(Duration(milliseconds: (math.max(0, rec.start - 3) * 1000).round()));
      setState(() => _ready = true);
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  void _applyMix() {
    final e = _engine, rec = _rec;
    if (e == null || rec == null) return;
    final m = rec.mix;
    e.setTrackGain(_acc, m.vocalOnly ? 0 : m.accompaniment);
    e.setTrackGain(_dry, m.dryGain);
    e.setTrackGain(_wet, m.wetGain);
    // Negative near the song start (the voice moved earlier): the engine
    // skips the beginning of the voice, like the export does.
    final at = ((rec.start + m.offsetMs / 1000) * _sr).round();
    e.setTrackOffset(_dry, at);
    e.setTrackOffset(_wet, at);
  }

  void _change(void Function(MixSettings m) edit) {
    final rec = _rec;
    if (rec == null) return;
    setState(() {
      edit(rec.mix);
      _exported = null;
    });
    _applyMix();
  }

  void _togglePlay() {
    final e = _engine;
    if (e == null) return;
    if (e.isPlaying) {
      e.pause();
    } else {
      try {
        if (widget.engineFactory == null) NativeAudio.configureSession(record: false);
        // Every time: after unplugged headphones or a call the engine is
        // silenced until it is started again (a no-op while it runs).
        e.takeAudioEvents();
        e.start();
        _deviceOn = true;
        if (e.positionSeconds >= e.lengthSeconds - 0.05) e.seek(Duration.zero);
        e.play();
      } catch (err) {
        _snack('现在放不了声音：$err');
      }
    }
    _clock ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!mounted) return;
      _syncAwake(); // the preview reached its end
      setState(() {});
    });
    _syncAwake();
    setState(() {});
  }

  void _stopDevice() {
    final e = _engine;
    if (e == null) return;
    e.pause();
    if (_deviceOn) {
      try {
        e.stop();
      } catch (_) {}
      _deviceOn = false;
    }
    _syncAwake();
    if (mounted) setState(() {});
  }

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _export() async {
    final meta = _meta, rec = _rec;
    if (meta == null || rec == null || _progress != null) return;
    _engine?.pause();
    setState(() => _progress = 0);
    _syncAwake();
    try {
      final dir = widget.outputDir ?? await getApplicationDocumentsDirectory();
      dir.createSync(recursive: true);
      var base = '${dir.path}/${exportName(meta.title, DateTime.now())}';
      for (var n = 2; File('$base.m4a').existsSync() || File('$base.wav').existsSync(); n++) {
        base = '${dir.path}/${exportName(meta.title, DateTime.now())} ($n)';
      }
      final job = ExportJob(
        voicePath: _songs.recordingPath(widget.songId, rec),
        voiceStart: rec.start,
        accompanimentPath: meta.accompanimentFile == null
            ? null
            : _songs.pathFor(widget.songId, meta.accompanimentFile!),
        songDuration: meta.duration,
        settings: rec.mix.copy(),
        outputBase: base,
      );
      final path = widget.background
          ? await runExport(
              job,
              onProgress: (f) {
                if (mounted) setState(() => _progress = f);
              },
            )
          : exportNow(job.toMessage());
      await _songs.saveRecording(widget.songId, rec);
      if (!mounted) return;
      setState(() {
        _progress = null;
        _exported = path;
      });
      _share(path);
    } catch (e) {
      if (!mounted) return;
      setState(() => _progress = null);
      _snack('导出失败：$e');
    } finally {
      if (mounted) _syncAwake();
    }
  }

  void _share(String path) {
    final shared = (widget.share ?? NativeAudio.shareFile)(path);
    if (!shared) _snack('已保存：$path');
  }

  Future<void> _delete() async {
    final rec = _rec;
    if (rec == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除这段录音？'),
        content: const Text('已经导出的成品不受影响。'),
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
    _stopDevice();
    _rec = null; // nothing to save on the way out
    await _songs.deleteRecording(widget.songId, rec);
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final rec = _rec, meta = _meta;
    return Scaffold(
      appBar: AppBar(
        title: const Text('制作成品'),
        actions: [
          if (rec != null)
            PopupMenuButton<String>(
              icon: const Icon(Icons.more_horiz_rounded),
              onSelected: (_) => _delete(),
              itemBuilder: (_) => const [PopupMenuItem(value: 'delete', child: Text('删除这段录音'))],
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _error != null
          ? Padding(padding: const EdgeInsets.all(24), child: Text('读不到这段录音：$_error'))
          : rec == null || meta == null
          ? const Center(child: CircularProgressIndicator())
          : _body(context, meta, rec),
    );
  }

  Widget _body(BuildContext context, SongMeta meta, Recording rec) {
    final p = context.yt;
    final m = rec.mix;
    final e = _engine;
    final playing = e?.isPlaying ?? false;
    final length = math.max(meta.duration, e?.lengthSeconds ?? 0);
    final pos = (e?.positionSeconds ?? 0).clamp(0.0, length > 0 ? length : 1.0);
    final hasAcc = meta.accompanimentFile != null;
    Widget slider(String title, String value, String? hint, Slider slider) => Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Text(title, style: context.type.bodyLarge),
              const Spacer(),
              Text(value, style: context.type.bodyMedium?.copyWith(fontFeatures: tabular)),
            ],
          ),
          if (hint != null) Text(hint, style: context.type.bodySmall),
          slider,
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 0, 20, 32),
      children: [
        Text(meta.title, style: context.type.headlineSmall),
        const SizedBox(height: 4),
        Text(
          '${_dateLabel(rec.createdAt)} 录的，${clock(rec.duration)}'
          '${rec.score == null ? '' : '，${rec.score!.round()} 分'}',
          style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
        ),
        const SizedBox(height: 18),
        // Preview.
        Row(
          children: [
            SizedBox(
              width: 56,
              height: 56,
              child: FilledButton(
                onPressed: _ready ? _togglePlay : null,
                style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                child: _ready
                    ? Icon(playing ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 30)
                    : const SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2)),
              ),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Slider(
                    value: pos.toDouble(),
                    max: length > 0 ? length : 1,
                    onChanged: _ready
                        ? (v) => setState(() => e!.seek(Duration(milliseconds: (v * 1000).round())))
                        : null,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 24),
                    child: Row(
                      children: [
                        Text(clock(pos.toDouble()), style: context.type.labelSmall?.copyWith(fontFeatures: tabular)),
                        const Spacer(),
                        Text(
                          _ready ? clock(length) : '正在准备试听…',
                          style: context.type.labelSmall?.copyWith(fontFeatures: tabular),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        if (hasAcc)
          SegmentedButton<bool>(
            segments: const [
              ButtonSegment(value: false, label: Text('人声 + 伴奏')),
              ButtonSegment(value: true, label: Text('只要人声')),
            ],
            selected: {m.vocalOnly},
            onSelectionChanged: (v) => _change((m) => m.vocalOnly = v.first),
          ),
        slider(
          '人声',
          '${(m.vocal * 100).round()}%',
          null,
          Slider(value: m.vocal, max: 1.5, onChanged: (v) => _change((m) => m.vocal = v)),
        ),
        if (hasAcc && !m.vocalOnly)
          slider(
            '伴奏',
            '${(m.accompaniment * 100).round()}%',
            null,
            Slider(value: m.accompaniment, max: 1.5, onChanged: (v) => _change((m) => m.accompaniment = v)),
          ),
        slider(
          '混响',
          '${(m.reverb * 100).round()}%',
          '让人声更饱满，像在房间里唱',
          Slider(value: m.reverb, onChanged: (v) => _change((m) => m.reverb = v)),
        ),
        slider(
          '人声对齐',
          '${m.offsetMs >= 0 ? '+' : ''}${m.offsetMs.round()} ms',
          '人声比伴奏慢，就往左拉；比伴奏快，就往右拉',
          Slider(
            value: m.offsetMs,
            min: -300,
            max: 300,
            divisions: 60,
            onChanged: (v) => _change((m) => m.offsetMs = v),
          ),
        ),
        const SizedBox(height: 10),
        SegmentedButton<bool>(
          segments: const [
            ButtonSegment(value: true, label: Text('整首歌')),
            ButtonSegment(value: false, label: Text('只要唱了的部分')),
          ],
          selected: {m.wholeSong},
          onSelectionChanged: (v) => _change((m) => m.wholeSong = v.first),
        ),
        if (m.vocalOnly && m.wholeSong)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text('只要人声、整首歌：和原曲一样长，在别的 App 里能直接和伴奏对齐。', style: context.type.bodySmall),
          ),
        const SizedBox(height: 8),
        Text('戴耳机录的成品最干净：外放时麦克风也会录进伴奏。', style: context.type.bodySmall),
        const SizedBox(height: 20),
        if (_progress != null) ...[
          LinearProgressIndicator(value: _progress),
          const SizedBox(height: 8),
          Text('正在合成和编码…', style: context.type.bodySmall),
        ] else
          FilledButton.icon(onPressed: _export, icon: const Icon(Icons.ios_share_rounded), label: const Text('导出成品')),
        if (_exported != null) ...[
          const SizedBox(height: 16),
          Container(
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text('已导出 ${_exported!.split('/').last}', style: context.type.bodyMedium),
                const SizedBox(height: 4),
                Text('在「文件」App 的 我的 iPhone › YinTrace 里也能找到。', style: context.type.bodySmall),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton.icon(
                    onPressed: () => _share(_exported!),
                    icon: const Icon(Icons.ios_share_rounded),
                    label: const Text('分享或存到别处'),
                  ),
                ),
              ],
            ),
          ),
        ],
      ],
    );
  }
}

String _dateLabel(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.month} 月 ${t.day} 日 ${two(t.hour)}:${two(t.minute)}';
}
