import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../analysis/corrections.dart';
import '../analysis/hubertfa_lexicon.dart';
import '../analysis/lyrics_language.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/pitch_correction_session.dart';
import '../app/services.dart';
import '../audio/audio_backend.dart';
import '../dsp/guide_tone.dart';
import '../models/model_catalog.dart';
import '../practice/segment_player.dart';
import 'lyrics_style.dart';
import 'model_setup.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

export '../app/pitch_correction_session.dart' show retimeLineInBackground;

Float32List _decodeMono(String path) => const NativeAudioBackend().decode(path, sampleRate: 44100, channels: 1).samples;

/// Decodes a song's vocal track in a background isolate. Top level, so the
/// isolate's closure captures nothing but the path.
Future<Float32List> decodeMonoInBackground(String path) => Isolate.run(() => _decodeMono(path));

/// Fix single characters (or words) of a song: listen to the original
/// singer and to the target note; set where a character starts when the
/// aligner put it in the wrong place (the rest of its line follows); move
/// a character's notes by semitones or octaves, leave it out of the score,
/// or give it a note where none was detected. Changes save automatically
/// after a series of timing taps.
class PitchEditorPage extends StatefulWidget {
  const PitchEditorPage({
    super.key,
    required this.songId,
    this.line = 0,
    this.playerFactory,
    this.decodeInBackground = true,
    this.retimer,
  });

  final String songId;

  /// The line to open.
  final int line;

  /// For tests.
  final SegmentPlayer Function()? playerFactory;

  /// Decode and align off the UI isolate (tests turn it off).
  final bool decodeInBackground;

  /// Replaces the timing aligner in tests.
  final TimingRetimer? retimer;

  @override
  State<PitchEditorPage> createState() => _PitchEditorPageState();
}

class _PitchEditorPageState extends State<PitchEditorPage> with WidgetsBindingObserver {
  late final AppServices _services;
  late final PitchCorrectionSession _session;
  late int _line = widget.line;
  int? _token;
  bool _loaded = false;
  bool _attached = false;
  bool _selectedFirstToken = false;
  bool _obtainingModel = false;
  int _seenNotice = 0;
  late final SegmentPlayer _player = widget.playerFactory?.call() ?? SegmentPlayer();
  Future<Float32List?>? _vocal;

  static const _sr = 44100;

  SongReference? get _ref => _session.reference;
  PitchTrack? get _track => _session.track;
  bool get _editingLine => _session.editingLine;
  bool get _timingBusy => _session.timingBusy;
  bool get _usesHubertFa => _session.usesHubertFa;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _player.addListener(_onPlayer);
  }

  void _onPlayer() {
    if (_attached) setState(() {});
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_loaded) return;
    _loaded = true;
    _services = AppScope.of(context);
    _session = _services.pitchCorrections.attach(widget.songId, () => PitchCorrectionSession(
      songId: widget.songId,
      songs: _services.songs,
      alignInBackground: widget.decodeInBackground,
      retimer: widget.retimer,
    ));
    _attached = true;
    _seenNotice = _session.noticeRevision;
    _session.addListener(_onCorrection);
    _onCorrection();
  }

  void _onCorrection() {
    setState(() {
      final ref = _ref;
      if (ref != null && !_selectedFirstToken) {
        _selectedFirstToken = true;
        _line = ref.lines.isEmpty ? 0 : _line.clamp(0, ref.lines.length - 1);
        _token = ref.lines.isEmpty ? null : _firstToken(ref.lines[_line]);
      }
    });
    if (_seenNotice != _session.noticeRevision) {
      _seenNotice = _session.noticeRevision;
      if (ModalRoute.isCurrentOf(context) == true) _snack(_session.notice!);
    }
  }

  void _detachCorrection() {
    if (!_attached) return;
    _attached = false;
    if (_player.playing) _player.stop();
    _session.removeListener(_onCorrection);
    _services.pitchCorrections.detach(_session);
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _player.suspend();
    if (state == AppLifecycleState.hidden && _attached) _session.flushNudges();
  }

  @override
  void dispose() {
    _detachCorrection();
    WidgetsBinding.instance.removeObserver(this);
    _player.removeListener(_onPlayer);
    _player.dispose();
    super.dispose();
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
    final path = _session.vocalPath;
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
    final from = math.max(0.0, (tok?.slotStart ?? line.start) - 0.12);
    final to = (tok?.end ?? line.end) + 0.25;
    Float32List? vocal;
    if (original) {
      final all = await _vocalAudio();
      if (!_attached) return;
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
    final token = _token;
    if (_attached && token != null && _selected != null) await _session.changePitch(_line, token, edit);
  }

  Future<String?> _requireHubertModel() async {
    if (_obtainingModel) return null;
    _obtainingModel = true;
    try {
      if (!await ensureModels(context, requiredModels: [hubertFaModel]) || !mounted || !_attached) return null;
      return _services.models.pathFor(hubertFaModel);
    } finally {
      _obtainingModel = false;
    }
  }

  Future<void> _restoreLine() async {
    final ref = _ref;
    if (ref == null) return;
    final line = _line;
    final needsModel = _usesHubertFa && ref.lines[line].tokens.any((t) => t.pinned != null || t.pinyinOverride != null);
    final path = needsModel ? await _requireHubertModel() : null;
    if (!mounted || !_attached || (needsModel && path == null)) return;
    if (needsModel) _player.stop();
    await _session.restoreLine(line, modelPath: path);
  }

  Future<void> _restoreToken() async {
    final line = _line, k = _token;
    final token = _selected;
    if (k == null || token == null) return;
    final needsModel = _usesHubertFa && (token.pinned != null || token.pinyinOverride != null);
    final path = needsModel ? await _requireHubertModel() : null;
    if (!mounted || !_attached || (needsModel && path == null)) return;
    if (needsModel) _player.stop();
    await _session.restoreToken(line, k, modelPath: path);
  }

  Future<void> _editPinyin(int tokenIndex) async {
    final ref = _ref!;
    final lineIndex = _line;
    final tokens = ref.lines[lineIndex].tokens;
    final token = tokens[tokenIndex];
    final line = _session.lyricLine(lineIndex);
    final automatic = mandarinPinyin(line.tokens)[tokenIndex];
    var input = token.pinyinOverride ?? automatic ?? '';
    final answer = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('修改「${token.text}」的拼音'),
        content: TextFormField(
          initialValue: input,
          onChanged: (text) => input = text,
          onFieldSubmitted: (text) => Navigator.pop(context, text),
          autofocus: true,
          autocorrect: false,
          textInputAction: TextInputAction.done,
          decoration: InputDecoration(
            labelText: '拼音',
            helperText: automatic == null ? '例如 zhang 或 zhang3' : '自动读音：$automatic',
          ),
        ),
        actions: [
          if (token.pinyinOverride != null)
            TextButton(onPressed: () => Navigator.pop(context, ''), child: const Text('用自动读音')),
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
          FilledButton(onPressed: () => Navigator.pop(context, input), child: const Text('重新对齐这一句')),
        ],
      ),
    );
    if (answer == null || !mounted) return;
    final pinyin = normalizePinyin(answer);
    final override = pinyin.isEmpty ? null : pinyin;
    if (override == token.pinyinOverride) return;
    final path = await _requireHubertModel();
    if (path == null || !mounted || !_attached) return;
    _player.stop();
    await _session.editReading(lineIndex, tokenIndex, override, path);
  }

  /// Includes requested starts that have not yet been aligned.
  double _startOf(int k) => _session.startOf(_line, k);

  Future<void> _setStart(double seconds, {bool nudge = false}) async {
    final line = _line, token = _token;
    if (!_attached || _editingLine || token == null || _track == null || _selected == null) return;
    String? modelPath;
    if (_usesHubertFa && widget.retimer == null) {
      modelPath = _services.models.pathFor(hubertFaModel) ?? await _requireHubertModel();
      if (modelPath == null || !mounted || !_attached) return;
      if (_player.playing) _player.stop();
    }
    _session.setStart(line, token, seconds, nudge: nudge, modelPath: modelPath);
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
  Widget build(BuildContext context) => PopScope<void>(
    onPopInvokedWithResult: (didPop, _) {
      if (didPop) _detachCorrection();
    },
    child: _buildEditor(context),
  );

  Widget _buildEditor(BuildContext context) {
    final error = _session.loadError;
    if (error != null) {
      return Scaffold(
        appBar: AppBar(),
        body: Padding(padding: const EdgeInsets.all(24), child: Text('这首歌的数据读取失败：$error')),
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
        appBar: AppBar(title: const Text('校正')),
        body: const Center(child: Text('这首歌没有歌词')),
      );
    }
    final line = ref.lines[_line];
    final lineCorrected = line.tokens.any((t) => t.corrected);
    // An adjacent HuBERTFA edit can change this line's timing bounds.
    final canSwitchLine = !_timingBusy || !_usesHubertFa;
    return Scaffold(
      appBar: AppBar(
        title: const Text('校正'),
        bottom: _editingLine
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            enabled: lineCorrected && !_editingLine && !_timingBusy,
            onSelected: (_) => _restoreLine(),
            itemBuilder: (_) => const [PopupMenuItem(value: 'restore', child: Text('这一句全部恢复自动识别'))],
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: AbsorbPointer(
        absorbing: _editingLine,
        child: ListView(
          padding: const EdgeInsets.fromLTRB(20, 0, 20, 28),
          children: [
            Text(
              '听一听原唱和目标音。哪个${ref.language.unit}的位置不对，调它开始的时间；音不对，就把目标音调到和原唱一样。'
              '停下调整后会自动保存，练习和打分都用改过的。',
              style: context.type.bodySmall,
            ),
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
                    onPressed: canSwitchLine && _line > 0 ? () => _goToLine(_line - 1) : null,
                    icon: const Icon(Icons.chevron_left_rounded),
                    label: const Text('上一句'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: canSwitchLine && _line + 1 < ref.lines.length ? () => _goToLine(_line + 1) : null,
                    icon: const Icon(Icons.chevron_right_rounded),
                    label: const Text('下一句'),
                  ),
                ),
              ],
            ),
          ],
        ),
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
    var t0 = line.start - 0.3, t1 = math.max(line.end, line.start + 1) + 0.3;
    final pins = _session.pendingPins(_line);
    final offsets = <RefToken, double>{};
    for (final (k, token) in line.tokens.indexed) {
      final pin = pins[k];
      if (pin == null || pin == token.slotStart) continue;
      final offset = pin - token.slotStart;
      offsets[token] = offset;
      final previewStart = math.min(token.start, token.slotStart) + offset;
      final previewEnd = token.end + offset;
      if (previewStart < t0) t0 = previewStart - 0.3;
      if (previewEnd > t1) t1 = previewEnd + 0.3;
    }
    final tok = _selected;
    final selectedOffset = offsets[tok] ?? 0.0;
    const gutter = 30.0;
    double timeAt(double x, double width) => t0 + (x - gutter) / (width - gutter) * (t1 - t0);
    return LayoutBuilder(
      builder: (context, c) => GestureDetector(
        onTapUp: (d) {
          final t = timeAt(d.localPosition.dx, c.maxWidth);
          var best = -1;
          var distance = double.infinity;
          var startDistance = double.infinity;
          for (final (k, token) in line.tokens.indexed) {
            final offset = offsets[token] ?? 0.0;
            final start = token.start + offset, end = token.end + offset;
            final fromSpan = t < start ? start - t : (t > end ? t - end : 0.0);
            final fromStart = (t - start).abs();
            // Where previews overlap, prefer the closest displayed onset.
            if (fromSpan < distance || (offsets.isNotEmpty && fromSpan == distance && fromStart < startDistance)) {
              distance = fromSpan;
              startDistance = fromStart;
              best = k;
            }
          }
          if (best >= 0) setState(() => _token = best);
        },
        // Long press: the selected character starts here.
        onLongPressStart: _track == null ? null : (d) => _setStart(timeAt(d.localPosition.dx, c.maxWidth)),
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
              highlight: tok == null ? null : (tok.slotStart + selectedOffset, tok.end + selectedOffset),
              tokenTimeOffsets: offsets,
              revision: _session.revision,
            ),
          ),
        ),
      ),
    );
  }

  /// Where the selected token starts, and buttons to move it.
  Widget _timing(BuildContext context, SongReference ref, RefLine line, RefToken tok) {
    final p = context.yt;
    final unit = ref.language.unit;
    final k = line.tokens.indexOf(tok);
    final start = _startOf(k);
    final canMove = _track != null;
    Widget nudge(IconData icon, String label, String tip, double by) => Expanded(
      child: Tooltip(
        message: tip,
        child: OutlinedButton.icon(
          onPressed: canMove ? () => _setStart(_startOf(k) + by, nudge: true) : null,
          icon: Icon(icon, size: 18),
          label: Text(label, style: TextStyle(fontFeatures: tabular)),
          style: OutlinedButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 4)),
        ),
      ),
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Text('从 ${_seconds(start)} 开始', style: context.type.titleSmall?.copyWith(fontFeatures: tabular)),
            const SizedBox(width: 8),
            if (tok.pinned != null || _session.pendingPins(_line)[k] != null)
              Text('你调过', style: context.type.labelSmall?.copyWith(color: p.inkSoft)),
            const Spacer(),
            if (_session.aligningTiming)
              const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            nudge(Icons.keyboard_double_arrow_left_rounded, '0.2', '提前 0.2 秒', -0.2),
            const SizedBox(width: 6),
            nudge(Icons.chevron_left_rounded, '0.05', '提前 0.05 秒', -0.05),
            const SizedBox(width: 6),
            nudge(Icons.chevron_right_rounded, '0.05', '推后 0.05 秒', 0.05),
            const SizedBox(width: 6),
            nudge(Icons.keyboard_double_arrow_right_rounded, '0.2', '推后 0.2 秒', 0.2),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          canMove
              ? '原唱已经唱到这个$unit、这里还算在前一个$unit上时，把它提前；也可以长按上面的图，把它的开头放到那里。'
                    '音高图会立即预览位置，停下后重新对齐这一句。'
              : '读不到原唱的音高曲线，不能调整位置。',
          style: context.type.bodySmall,
        ),
      ],
    );
  }

  Widget _panel(BuildContext context, SongReference ref, RefLine line, RefToken tok) {
    final p = context.yt;
    final unit = ref.language.unit;
    final has = tok.notes.isNotEmpty;
    final canEditPitch = _session.canEditPitch;
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
        onPressed: canEditPitch && has && !tok.skip ? () => _change((t) => t.transpose(semis)) : null,
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
            if (ref.language != LyricsLanguage.japanese && isMandarinToken(tok.text) && _track != null)
              TextButton(
                onPressed: !_timingBusy ? () => _editPinyin(_token!) : null,
                style: TextButton.styleFrom(
                  minimumSize: const Size(0, 36),
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text('修改拼音'),
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
        const SizedBox(height: 16),
        _timing(context, ref, line, tok),
        const SizedBox(height: 16),
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
            onPressed: canEditPitch ? () => _change((t) => addManualNote(t, line, _track)) : null,
            icon: const Icon(Icons.add_rounded),
            label: Text('给这个$unit加上目标音'),
          ),
        if (has)
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: Text('这个$unit不计分'),
            subtitle: const Text('原唱这里听不清、是念白或和声时打开'),
            value: tok.skip,
            onChanged: canEditPitch ? (v) => _change((t) => t.skip = v) : null,
          ),
        if (tok.corrected)
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              onPressed: _timingBusy ? null : _restoreToken,
              icon: const Icon(Icons.undo_rounded),
              label: const Text('恢复自动识别'),
            ),
          ),
      ],
    );
  }
}

String _seconds(double s) {
  final m = s ~/ 60;
  final rest = s - m * 60;
  return '$m:${rest.toStringAsFixed(2).padLeft(5, '0')}';
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
