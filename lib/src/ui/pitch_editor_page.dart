import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../analysis/corrections.dart';
import '../analysis/lyrics_language.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/services.dart';
import '../audio/audio_backend.dart';
import '../dsp/guide_tone.dart';
import '../library/song.dart';
import '../practice/segment_player.dart';
import 'lyrics_style.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

Float32List _decodeMono(String path) => const NativeAudioBackend().decode(path, sampleRate: 44100, channels: 1).samples;

/// Decodes a song's vocal track in a background isolate. Top level, so the
/// isolate's closure captures nothing but the path.
Future<Float32List> decodeMonoInBackground(String path) => Isolate.run(() => _decodeMono(path));

/// Fix the target pitch of single characters (or words) of a song: listen
/// to the original singer and to the target note, move a character's notes
/// by semitones or octaves, leave it out of the score, or give it a note
/// where none was detected. Every change is saved at once; the detected
/// melody can always be restored.
class PitchEditorPage extends StatefulWidget {
  const PitchEditorPage({
    super.key,
    required this.songId,
    this.line = 0,
    this.playerFactory,
    this.decodeInBackground = true,
  });

  final String songId;

  /// The line to open.
  final int line;

  /// For tests.
  final SegmentPlayer Function()? playerFactory;
  final bool decodeInBackground;

  @override
  State<PitchEditorPage> createState() => _PitchEditorPageState();
}

class _PitchEditorPageState extends State<PitchEditorPage> with WidgetsBindingObserver {
  SongMeta? _meta;
  SongReference? _ref;
  PitchTrack? _track;
  String? _error;
  late int _line = widget.line;
  int? _token;
  int _revision = 0;
  late final SegmentPlayer _player = widget.playerFactory?.call() ?? SegmentPlayer();
  Future<Float32List?>? _vocal;
  bool _loaded = false;

  static const _sr = 44100;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player.addListener(_onPlayer);
  }

  void _onPlayer() {
    if (mounted) setState(() {});
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
    if (state != AppLifecycleState.resumed) _player.suspend();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_onPlayer);
    _player.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final repo = AppScope.of(context).songs;
    try {
      final meta = await repo.load(widget.songId);
      final ref = await repo.loadReference(widget.songId);
      PitchTrack? track;
      try {
        track = await repo.loadPitchTrack(widget.songId);
      } catch (_) {
        // Drawn without the original singer's contour.
      }
      if (!mounted) return;
      setState(() {
        _meta = meta;
        _ref = ref;
        _track = track;
        _line = ref.lines.isEmpty ? 0 : _line.clamp(0, ref.lines.length - 1);
        _token = ref.lines.isEmpty ? null : _firstToken(ref.lines[_line]);
      });
    } catch (e) {
      if (mounted) setState(() => _error = '$e');
    }
  }

  /// The first token worth looking at: a corrected one, else one without
  /// pitch, else the first.
  static int? _firstToken(RefLine line) {
    if (line.tokens.isEmpty) return null;
    final corrected = line.tokens.indexWhere((t) => t.corrected);
    if (corrected >= 0) return corrected;
    final missing = line.tokens.indexWhere((t) => t.notes.isEmpty);
    return missing >= 0 ? missing : 0;
  }

  RefToken? get _selected {
    final ref = _ref, k = _token;
    if (ref == null || k == null || ref.lines.isEmpty) return null;
    final tokens = ref.lines[_line].tokens;
    return k < tokens.length ? tokens[k] : null;
  }

  /// The original vocal (mono, 44.1 kHz), decoded on first use.
  Future<Float32List?> _vocalAudio() => _vocal ??= () async {
    final path = AppScope.of(context).songs.pathFor(widget.songId, _meta!.vocalsFile);
    try {
      return widget.decodeInBackground ? await decodeMonoInBackground(path) : _decodeMono(path);
    } catch (_) {
      return null;
    }
  }();

  void _snack(String text) {
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }

  Future<void> _listen({required bool original, required bool tone}) async {
    final ref = _ref;
    if (ref == null) return;
    final line = ref.lines[_line];
    final tok = _selected;
    final from = math.max(0.0, (tok?.start ?? line.start) - 0.12);
    final to = (tok?.end ?? line.end) + 0.25;
    Float32List? vocal;
    if (original) {
      final all = await _vocalAudio();
      if (!mounted) return;
      if (all == null) {
        _snack('读不到原唱人声');
        return;
      }
      final a = (from * _sr).round().clamp(0, all.length).toInt();
      final b = (to * _sr).round().clamp(a, all.length).toInt();
      vocal = Float32List.sublistView(all, a, b);
    }
    final notes = tok?.notes ?? line.scoredNotes.toList();
    final guide = tone ? guideTone([for (final n in notes) (n.start, n.end, n.midi)], from, to) : null;
    try {
      _player.play(vocal: vocal, tone: guide, vocalGain: 1, toneGain: original ? 0.6 : 1);
    } catch (e) {
      _snack('现在放不了声音：$e');
    }
  }

  Future<void> _change(void Function(RefToken token) edit) async {
    final tok = _selected;
    if (tok == null) return;
    setState(() {
      edit(tok);
      _revision++;
    });
    await _save();
  }

  Future<void> _save() async {
    try {
      await AppScope.of(context).songs.saveReference(widget.songId, _ref!);
    } catch (e) {
      _snack('没能保存：$e');
    }
  }

  Future<void> _restoreLine() async {
    final ref = _ref;
    if (ref == null) return;
    setState(() {
      for (final t in ref.lines[_line].tokens) {
        t.restore();
      }
      _revision++;
    });
    await _save();
  }

  void _goToLine(int line) {
    final ref = _ref;
    if (ref == null || line < 0 || line >= ref.lines.length) return;
    _player.stop();
    setState(() {
      _line = line;
      _token = _firstToken(ref.lines[line]);
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('这首歌的数据读取失败：$_error')),
      );
    }
    final ref = _ref;
    if (ref == null) {
      return Scaffold(
        appBar: AppBar(),
        body: const Center(child: CircularProgressIndicator()),
      );
    }
    if (ref.lines.isEmpty) {
      return Scaffold(
        appBar: AppBar(title: const Text('校正音高')),
        body: const Center(child: Text('这首歌没有歌词')),
      );
    }
    final line = ref.lines[_line];
    final lineCorrected = line.tokens.any((t) => t.corrected);
    return Scaffold(
      appBar: AppBar(
        title: const Text('校正音高'),
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            enabled: lineCorrected,
            onSelected: (_) => _restoreLine(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'restore', child: Text('这一句全部恢复自动识别'))],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
        children: [
          Text('听一听原唱和目标音；不一样，就把目标音调到和原唱一样。改动马上保存，练习和打分都用改过的。', style: context.type.bodySmall),
          const SizedBox(height: 14),
          Text('第 ${_line + 1} 句，共 ${ref.lines.length} 句', style: context.type.labelMedium),
          const SizedBox(height: 8),
          _TokenChips(
            line: line,
            selected: _token,
            language: ref.language,
            onSelect: (k) => setState(() => _token = k),
          ),
          const SizedBox(height: 12),
          _graph(context, ref, line),
          const SizedBox(height: 6),
          Text('细灰线是原唱实际唱出的音高，粗线是练习时的目标音。', style: context.type.labelSmall),
          const SizedBox(height: 18),
          if (_selected != null) _panel(context, ref, line, _selected!),
          const SizedBox(height: 22),
          Row(
            children: [
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _line > 0 ? () => _goToLine(_line - 1) : null,
                  icon: const Icon(Icons.chevron_left_rounded),
                  label: const Text('上一句'),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _line + 1 < ref.lines.length ? () => _goToLine(_line + 1) : null,
                  icon: const Icon(Icons.chevron_right_rounded),
                  label: const Text('下一句'),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _graph(BuildContext context, SongReference ref, RefLine line) {
    var lo = double.infinity, hi = -double.infinity;
    for (final n in line.notes) {
      lo = math.min(lo, n.midi);
      hi = math.max(hi, n.midi);
    }
    if (lo > hi) {
      final r = ref.pitchRange;
      lo = r.$1;
      hi = r.$2;
    }
    final (a, b) = paddedRange(lo, hi, minSpan: 12, pad: 3);
    final t0 = line.start - 0.3, t1 = math.max(line.end, line.start + 1) + 0.3;
    final tok = _selected;
    const gutter = 30.0;
    return LayoutBuilder(
      builder: (context, c) => GestureDetector(
        onTapUp: (d) {
          final t = t0 + (d.localPosition.dx - gutter) / (c.maxWidth - gutter) * (t1 - t0);
          var best = -1;
          var dist = double.infinity;
          for (var k = 0; k < line.tokens.length; k++) {
            final x = line.tokens[k];
            final dd = t < x.start ? x.start - t : (t > x.end ? t - x.end : 0.0);
            if (dd < dist) {
              dist = dd;
              best = k;
            }
          }
          if (best >= 0) setState(() => _token = best);
        },
        child: SizedBox(
          height: 230,
          child: CustomPaint(
            size: Size.infinite,
            painter: PitchGraphPainter(
              reference: SongReference(lines: [line], duration: ref.duration, language: ref.language),
              contour: _track,
              t0: t0,
              t1: t1,
              midiLo: a,
              midiHi: b + 1.5,
              style: PitchGraphStyle.of(context, language: ref.language),
              gutter: gutter,
              glyphSize: 15,
              highlight: tok == null ? null : (tok.start, tok.end),
              revision: _revision,
            ),
          ),
        ),
      ),
    );
  }

  Widget _panel(BuildContext context, SongReference ref, RefLine line, RefToken tok) {
    final p = context.yt;
    final unit = ref.language.unit;
    final has = tok.notes.isNotEmpty;
    final String detail;
    if (!has) {
      detail = '没测到原唱音高，不计分。可以加上一个目标音，再按原唱调准。';
    } else if (tok.manual) {
      detail = '这是你加的目标音。';
    } else if (tok.shift != 0) {
      final s = tok.shift.round();
      final what = s.abs() % 12 == 0 ? '${s.abs() ~/ 12} 个八度' : '${s.abs()} 个半音';
      detail = '自动识别是 ${noteLabel(tok.meanMidi - tok.shift)}，你${s > 0 ? '调高' : '调低'}了 $what。';
    } else {
      detail = '自动识别的音高。';
    }
    final playing = _player.playing;
    Widget listen(String label, IconData icon, {required bool original, required bool tone}) => Expanded(
      child: OutlinedButton.icon(
        onPressed: playing || (tone && !has && !original) ? null : () => _listen(original: original, tone: tone),
        icon: Icon(icon, size: 18),
        label: Text(label),
        style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 6)),
      ),
    );
    Widget step(String label, double semis) => Expanded(
      child: FilledButton.tonal(
        onPressed: has && !tok.skip ? () => _change((t) => t.transpose(semis)) : null,
        style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
        child: Text(label),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            Flexible(
              child: Text(
                '「${tok.text}」',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: lyricsStyle(context.type.headlineMedium, ref.language),
              ),
            ),
            const SizedBox(width: 8),
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(
                tok.skip ? '不计分' : (has ? '目标音 ${noteLabel(tok.meanMidi)}' : '没有目标音'),
                style: context.type.titleMedium?.copyWith(color: tok.skip || !has ? p.inkFaint : p.ink),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Text(detail, style: context.type.bodySmall),
        const SizedBox(height: 14),
        Row(
          children: [
            listen('听原唱', Icons.record_voice_over_rounded, original: true, tone: false),
            const SizedBox(width: 8),
            listen('听目标音', Icons.music_note_rounded, original: false, tone: true),
            const SizedBox(width: 8),
            listen('一起听', Icons.join_inner_rounded, original: true, tone: true),
          ],
        ),
        if (playing)
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: _player.stop,
              icon: const Icon(Icons.stop_rounded),
              label: const Text('停止'),
            ),
          ),
        const SizedBox(height: 12),
        if (has)
          Row(
            children: [
              step('降八度', -12),
              const SizedBox(width: 6),
              step('降半音', -1),
              const SizedBox(width: 6),
              step('升半音', 1),
              const SizedBox(width: 6),
              step('升八度', 12),
            ],
          )
        else
          FilledButton.icon(
            onPressed: () => _change((t) => addManualNote(t, line, _track)),
            icon: const Icon(Icons.add_rounded),
            label: Text('给这个$unit加上目标音'),
          ),
        if (has)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('这个$unit不计分'),
            subtitle: const Text('原唱这里听不清、是念白或和声时打开'),
            value: tok.skip,
            onChanged: (v) => _change((t) => t.skip = v),
          ),
        if (tok.corrected)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: () => _change((t) => t.restore()),
              icon: const Icon(Icons.undo_rounded),
              label: const Text('恢复自动识别'),
            ),
          ),
      ],
    );
  }
}

/// The line's characters as chips; tap one to edit it.
class _TokenChips extends StatelessWidget {
  const _TokenChips({required this.line, required this.selected, required this.language, required this.onSelect});

  final RefLine line;
  final int? selected;
  final LyricsLanguage language;
  final void Function(int) onSelect;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: [
        for (final (k, t) in line.tokens.indexed)
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => onSelect(k),
            child: Container(
              constraints: const BoxConstraints(minWidth: 40),
              padding: const EdgeInsets.fromLTRB(10, 6, 10, 4),
              decoration: BoxDecoration(
                color: p.surface,
                borderRadius: BorderRadius.circular(10),
                border: Border.all(color: k == selected ? p.ink : p.hairline, width: k == selected ? 1.6 : 1),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    t.text,
                    style: lyricsStyle(context.type.titleMedium, language)?.copyWith(
                      color: t.skip || t.notes.isEmpty ? p.inkFaint : p.ink,
                      decoration: t.skip ? TextDecoration.lineThrough : null,
                    ),
                  ),
                  const SizedBox(height: 2),
                  // A dot under every corrected character.
                  Container(
                    width: 5,
                    height: 5,
                    decoration: BoxDecoration(shape: BoxShape.circle, color: t.corrected ? p.ink : Colors.transparent),
                  ),
                ],
              ),
            ),
          ),
      ],
    );
  }
}
