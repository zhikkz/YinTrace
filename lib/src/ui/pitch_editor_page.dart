import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../analysis/corrections.dart';
import '../analysis/hubertfa_lexicon.dart';
import '../analysis/lrc.dart';
import '../analysis/lyrics_language.dart';
import '../analysis/manual_timing.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/services.dart';
import '../audio/audio_backend.dart';
import '../dsp/guide_tone.dart';
import '../import/hubertfa_job.dart';
import '../library/song.dart';
import '../models/model_catalog.dart';
import '../practice/segment_player.dart';
import 'lyrics_style.dart';
import 'model_setup.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

Float32List _decodeMono(String path) => const NativeAudioBackend().decode(path, sampleRate: 44100, channels: 1).samples;

/// Decodes a song's vocal track in a background isolate. Top level, so the
/// isolate's closure captures nothing but the path.
Future<Float32List> decodeMonoInBackground(String path) => Isolate.run(() => _decodeMono(path));

/// [retimeLine] in a background isolate (top level for the same reason).
Future<SongReference> retimeLineInBackground(
  PitchTrack track,
  List<LyricLine> lines,
  SongReference current,
  int line,
  Map<int, double> pins,
) => Isolate.run(() => retimeLine(track, lines, current, line, pins));

/// Fix single characters (or words) of a song: listen to the original
/// singer and to the target note; set where a character starts when the
/// aligner put it in the wrong place (the rest of its line follows); move
/// a character's notes by semitones or octaves, leave it out of the score,
/// or give it a note where none was detected. Every change is saved at
/// once; what was detected can always be restored.
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

  /// Aligns a line again ([retimeLine] by default; tests can delay it).
  final Future<SongReference> Function(PitchTrack, List<LyricLine>, SongReference, int, Map<int, double>)? retimer;

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
  List<LyricLine>? _lyricLines;

  /// Lines waiting to be aligned again, with the pins asked for last.
  final Map<int, Map<int, double>> _wanted = {};
  Future<void>? _retimeQueue;
  int _retimesQueued = 0;
  bool _editingLine = false;
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
    final from = math.max(0.0, (tok?.slotStart ?? line.start) - 0.12);
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

  Future<void>? _saving;

  /// Saves the reference. Quick taps queue up: writes of the same file must
  /// not overlap (each writes the newest state).
  Future<void> _save() {
    final songs = AppScope.of(context).songs;
    final ref = _ref!;
    Future<void> write() async {
      try {
        await songs.saveReference(widget.songId, ref);
      } catch (e) {
        _snack('没能保存：$e');
      }
    }

    return _saving = (_saving ?? Future<void>.value()).then((_) => write());
  }

  Future<void> _restoreLine() async {
    final ref = _ref;
    if (ref == null) return;
    final line = _line;
    if (_usesHubertFa && ref.lines[line].tokens.any((t) => t.pinned != null || t.pinyinOverride != null)) {
      await _updateModelLine(line, pins: {}, readings: {}, restore: ref.lines[line].tokens.asMap().keys.toSet());
      return;
    }
    final moved = ref.lines[line].tokens.any((t) => t.pinned != null) || (_wanted[line]?.isNotEmpty ?? false);
    setState(() {
      for (final t in ref.lines[line].tokens) {
        t.restore();
      }
      _revision++;
    });
    await _save();
    if (moved) await _retime(line, const {});
  }

  /// Back to what was detected for the selected token; one that was placed
  /// by hand goes back to where the aligner puts it.
  Future<void> _restoreToken() async {
    final line = _line, k = _token;
    if (k != null && _usesHubertFa && (_selected!.pinned != null || _selected!.pinyinOverride != null)) {
      await _updateModelLine(line, pins: _pinsOfLine(line)..remove(k), readings: _readings(line)..remove(k), restore: {k});
      return;
    }
    final moved = _selected?.pinned != null || (_wanted[line]?.containsKey(k) ?? false);
    await _change((t) => t.restore());
    if (moved) await _retime(line, {...(_wanted[line] ?? _pinsOfLine(line))}..remove(k));
  }

  Map<int, double> _pinsOfLine(int line) => {for (final (i, t) in _ref!.lines[line].tokens.indexed) i: ?t.pinned};

  Future<void> _editPinyin(int tokenIndex) async {
    final ref = _ref!, meta = _meta!;
    final lineIndex = _line;
    final tokens = ref.lines[lineIndex].tokens;
    final token = tokens[tokenIndex];
    final line = (_lyricLines ??= linesOfReference(ref, meta.lyrics))[lineIndex];
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
    final readings = _readings(lineIndex);
    if (override == null) {
      readings.remove(tokenIndex);
    } else {
      readings[tokenIndex] = override;
    }
    await _updateModelLine(lineIndex, pins: _pinsOfLine(lineIndex), readings: readings);
  }

  bool get _usesHubertFa => _meta?.modelInfo['alignment'] == 'HuBERTFA' ||
      _ref!.lines.any((line) => line.hubertFa || line.tokens.any((t) => t.pinyinOverride != null));

  Map<int, String> _readings(int line) => {for (final (i, t) in _ref!.lines[line].tokens.indexed) i: ?t.pinyinOverride};

  Future<void> _updateModelLine(int lineIndex, {
    required Map<int, double> pins,
    required Map<int, String> readings,
    Set<int> restore = const {},
  }) async {
    final services = AppScope.of(context);
    final ref = _ref!, meta = _meta!, track = _track;
    if (track == null) {
      _snack('读不到原唱的音高曲线，不能重新对齐');
      return;
    }
    _player.stop();
    setState(() => _editingLine = true);
    try {
      if (!await ensureModels(context, requiredModels: [hubertFaModel]) || !mounted) return;
      await _saving;
      if (!mounted) return;
      final lines = _lyricLines ??= linesOfReference(ref, meta.lyrics);
      final fresh = await alignStoredLine(
        services.models.pathFor(hubertFaModel)!,
        services.songs.pathFor(widget.songId, meta.vocalsFile),
        track, lines[lineIndex], ref, lineIndex,
        pins: pins,
        readings: readings,
        restore: restore,
      );
      if (!mounted) return;
      await services.songs.saveReference(widget.songId, fresh);
      if (mounted) {
        setState(() {
          _ref = fresh;
          _revision++;
        });
      }
    } catch (e) {
      _snack('没能重新对齐：$e');
    } finally {
      if (mounted) setState(() => _editingLine = false);
    }
  }

  /// Where token [k] of the current line starts, counting a change that is
  /// still being aligned (so that quick taps add up).
  double _startOf(int k) => _wanted[_line]?[k] ?? _ref!.lines[_line].tokens[k].slotStart;

  /// Sets where the selected token starts (within what its neighbours
  /// allow) and aligns the rest of its line again around it.
  Future<void> _setStart(double seconds) async {
    final ref = _ref, k = _token;
    if (ref == null || k == null || _track == null || _selected == null) return;
    final (lo, hi) = pinRange(ref, _line, k, lineOnly: _usesHubertFa);
    final pin = seconds.clamp(lo, hi).toDouble();
    if ((pin - _startOf(k)).abs() < 0.002) {
      _snack(seconds < pin ? '再往前就碰到前面的$_unit了' : '再往后就碰到后面的$_unit了');
      return;
    }
    final pins = {...(_wanted[_line] ?? _pinsOfLine(_line)), k: pin};
    if (_usesHubertFa) {
      await _updateModelLine(_line, pins: pins, readings: _readings(_line));
    } else {
      await _retime(_line, pins);
    }
  }

  String get _unit => _ref?.language.unit ?? '字';

  /// Aligns [line] again with [pins] (its pins from now on), the rest of the
  /// song held. Requests are done one after another on the newest
  /// reference, a line's newest pins only; the corrections are taken from
  /// the reference as it is when the result arrives.
  Future<void> _retime(int line, Map<int, double> pins) {
    setState(() {
      _wanted[line] = pins;
      _retimesQueued++;
    });
    return _retimeQueue = (_retimeQueue ?? Future<void>.value()).then((_) async {
      try {
        await _retimeNow(line);
      } finally {
        if (mounted) setState(() => _retimesQueued--);
      }
    });
  }

  Future<void> _retimeNow(int line) async {
    // The line's newest pins; they stay asked for (and shown, and added to
    // by further taps) until a result with them is in.
    final pins = _wanted[line];
    final ref = _ref, track = _track, meta = _meta;
    if (pins == null || !mounted || ref == null || track == null || meta == null) return;
    void done() {
      if (identical(_wanted[line], pins)) _wanted.remove(line);
    }

    final lines = _lyricLines ??= linesOfReference(ref, meta.lyrics);
    SongReference fresh;
    try {
      fresh =
          await (widget.retimer?.call(track, lines, ref, line, pins) ??
              (widget.decodeInBackground
                  ? retimeLineInBackground(track, lines, ref, line, pins)
                  : Future.value(retimeLine(track, lines, ref, line, pins))));
    } catch (e) {
      done();
      _snack('没能重新对齐：$e');
      return;
    }
    if (!mounted) return;
    if (pins.keys.any((i) => fresh.lines[line].tokens[i].pinned == null)) {
      // No room for a pin there: nothing changes.
      setState(done);
      _snack('这里放不下，没有改');
      return;
    }
    fresh.applyCorrectionsFrom(_ref!);
    setState(() {
      _ref = fresh;
      _revision++;
      done();
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
        appBar: AppBar(title: const Text('校正')),
        body: const Center(child: Text('这首歌没有歌词')),
      );
    }
    final line = ref.lines[_line];
    final lineCorrected = line.tokens.any((t) => t.corrected);
    return Scaffold(
      appBar: AppBar(
        title: const Text('校正'),
        bottom: _editingLine
            ? const PreferredSize(preferredSize: Size.fromHeight(4), child: LinearProgressIndicator())
            : null,
        actions: [
          PopupMenuButton<String>(
            icon: const Icon(Icons.more_horiz_rounded),
            enabled: lineCorrected && !_editingLine,
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
              '改动马上保存，练习和打分都用改过的。',
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
        // Long press: the selected character starts here.
        onLongPressStart: _track == null
            ? null
            : (d) => _setStart(t0 + (d.localPosition.dx - gutter) / (c.maxWidth - gutter) * (t1 - t0)),
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
              highlight: tok == null ? null : (tok.slotStart, tok.end),
              revision: _revision,
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
          onPressed: canMove ? () => _setStart(_startOf(k) + by) : null,
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
            if (tok.pinned != null || _wanted[_line]?[k] != null)
              Text('你调过', style: context.type.labelSmall?.copyWith(color: p.inkSoft)),
            const Spacer(),
            if (_retimesQueued > 0)
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
                    '这一句其余的$unit会跟着重新对齐。'
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
            if (ref.language != LyricsLanguage.japanese && isMandarinToken(tok.text) && _track != null)
              TextButton(
                onPressed: _retimesQueued == 0 ? () => _editPinyin(_token!) : null,
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
              onPressed: _restoreToken,
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
