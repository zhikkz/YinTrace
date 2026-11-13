import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../dsp/pitch.dart';
import '../library/song.dart';
import '../practice/practice_session.dart';
import 'app.dart';
import 'pitch_graph.dart';
import 'results_sheet.dart';

/// The main practice screen: the per-character pitch map scrolls under a
/// playhead while the singer's live YIN pitch is drawn on top of it.
class PracticePage extends StatefulWidget {
  const PracticePage({
    super.key,
    required this.meta,
    required this.reference,
    this.contour,
    this.loopLine,
    this.sessionFactory,
  });

  final SongMeta meta;
  final SongReference reference;
  final PitchTrack? contour;
  final int? loopLine;

  /// For tests.
  final PracticeSession Function(BuildContext context)? sessionFactory;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> with SingleTickerProviderStateMixin {
  late final PracticeSession _session;
  late final Ticker _ticker;
  final _started = Stopwatch();
  bool _shownResults = false;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker((_) => _session.tick());
  }

  bool _init = false;
  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final services = AppScope.of(context);
    _session = widget.sessionFactory?.call(context) ??
        PracticeSession(
          meta: widget.meta,
          reference: widget.reference,
          contour: widget.contour,
          repository: services.songs,
          settings: services.settings,
          loopLine: widget.loopLine,
        );
    _session.addListener(_onSession);
    keepScreenOn(true);
    _session.start().then((_) {
      if (mounted) _ticker.start();
    });
  }

  void _onSession() {
    if (_session.finished && !_shownResults) {
      _shownResults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showResults(saveRecord: true));
    }
  }

  @override
  void dispose() {
    _ticker.dispose();
    _session.removeListener(_onSession);
    _session.dispose();
    keepScreenOn(false);
    super.dispose();
  }

  Future<void> _showResults({bool saveRecord = false}) async {
    _session.pause();
    _started.stop();
    PracticeRecord? record;
    if (saveRecord) record = await _session.save(elapsedSeconds: _started.elapsed.inMilliseconds / 1000);
    if (!mounted) return;
    final line = await showModalBottomSheet<int>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => ResultsSheet(scorer: _session.scorer, record: record, contour: widget.contour),
    );
    _shownResults = false;
    _session.finished = false;
    if (line != null) {
      _session.setLoopLine(line);
      _session.seekToLine(line);
    }
  }

  void _togglePlay() {
    if (!_session.isPlaying) _started.start();
    _session.togglePlay();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '练习设置',
            icon: const Icon(Icons.tune),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              showDragHandle: true,
              builder: (_) => _MixSheet(session: _session),
            ),
          ),
          IconButton(
            tooltip: '查看评分',
            icon: const Icon(Icons.insights),
            onPressed: () => _showResults(saveRecord: true),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          if (_session.error != null) {
            return Center(
                child: Padding(padding: const EdgeInsets.all(24), child: Text(_session.error!)));
          }
          if (!_session.started) {
            return const Center(
              child: Column(mainAxisSize: MainAxisSize.min, children: [
                CircularProgressIndicator(),
                SizedBox(height: 12),
                Text('正在载入伴奏和导唱…'),
              ]),
            );
          }
          return Column(
            children: [
              _LiveReadout(session: _session),
              Expanded(child: _Graph(session: _session, contour: widget.contour)),
              _Lyrics(session: _session),
              _Transport(session: _session, onPlay: _togglePlay),
            ],
          );
        },
      ),
    );
  }
}

class _LiveReadout extends StatelessWidget {
  const _LiveReadout({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final s = session.lastSample;
    final colors = PitchGraphColors.of(context);
    final theme = Theme.of(context);
    final voiced = s != null && s.pitch.voiced;
    final target = session.reference.noteAt(session.position);
    String dev = '';
    Color devColor = theme.colorScheme.onSurfaceVariant;
    if (voiced && s.deviationCents != null) {
      final c = s.deviationCents!.round();
      dev = c == 0 ? '准' : (c > 0 ? '高 $c' : '低 ${-c}');
      devColor = colors.verdict(s.verdict);
    }
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      child: Row(
        children: [
          _chip(context, '目标', target == null ? '—' : noteName(target.midi)),
          const SizedBox(width: 8),
          _chip(context, '你', voiced ? noteName(s.pitch.midi) : '—'),
          const SizedBox(width: 8),
          Text(dev, style: theme.textTheme.titleMedium?.copyWith(color: devColor)),
          const Spacer(),
          Text(session.loopLine != null ? '单句循环' : '整首',
              style: theme.textTheme.labelMedium),
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String value) {
    final theme = Theme.of(context);
    return Row(children: [
      Text('$label ', style: theme.textTheme.labelMedium),
      Text(value, style: theme.textTheme.titleMedium?.copyWith(fontFeatures: const [FontFeature.tabularFigures()])),
    ]);
  }
}

class _Graph extends StatelessWidget {
  const _Graph({required this.session, this.contour});
  final PracticeSession session;
  final PitchTrack? contour;

  @override
  Widget build(BuildContext context) {
    final settings = session.settings;
    final ph = session.position;
    final span = settings.practiceWindowSeconds;
    final t0 = ph - span * 0.35, t1 = ph + span * 0.65;
    // Vertical range: the notes around the visible window.
    var lo = double.infinity, hi = -double.infinity;
    for (final line in session.reference.lines) {
      if (line.end < t0 - 2 || line.start > t1 + 2) continue;
      for (final n in line.notes) {
        lo = lo < n.midi ? lo : n.midi;
        hi = hi > n.midi ? hi : n.midi;
      }
    }
    if (lo > hi) {
      final r = session.reference.pitchRange;
      lo = r.$1;
      hi = r.$2;
    }
    final (a, b) = paddedRange(lo, hi, minSpan: 14);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: CustomPaint(
          size: Size.infinite,
          painter: PitchGraphPainter(
            reference: session.reference,
            contour: contour,
            t0: t0,
            t1: t1,
            midiLo: a,
            midiHi: b,
            colors: PitchGraphColors.of(context),
            user: session.points,
            playhead: ph,
            tokenScores: session.tokenScores(),
          ),
        ),
      ),
    );
  }
}

class _Lyrics extends StatelessWidget {
  const _Lyrics({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final ref = session.reference;
    final li = session.currentLine;
    if (li < 0) return const SizedBox(height: 72);
    final line = ref.lines[li];
    final next = li + 1 < ref.lines.length ? ref.lines[li + 1] : null;
    final ph = session.position;
    final theme = Theme.of(context);
    final colors = PitchGraphColors.of(context);
    final scores = session.tokenScores();
    final base = theme.textTheme.headlineSmall!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 10, 16, 4),
      child: Column(
        children: [
          Text.rich(
            TextSpan(children: [
              for (final t in line.tokens)
                TextSpan(
                  text: '${t.spaceBefore ? ' ' : ''}${t.text}',
                  style: base.copyWith(
                    color: scores[t] != null
                        ? colors.score(scores[t]!)
                        : (ph >= t.start ? theme.colorScheme.primary : theme.colorScheme.onSurface),
                    fontWeight: ph >= t.start && ph < t.end ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
            ]),
            textAlign: TextAlign.center,
          ),
          const SizedBox(height: 4),
          Text(next?.text ?? '', style: theme.textTheme.bodyLarge?.copyWith(color: theme.colorScheme.outline)),
        ],
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.session, required this.onPlay});
  final PracticeSession session;
  final VoidCallback onPlay;

  @override
  Widget build(BuildContext context) {
    final dur = session.duration;
    final pos = session.position.clamp(0, dur > 0 ? dur : 1).toDouble();
    final li = session.currentLine;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
        child: Column(
          children: [
            Row(
              children: [
                Text(formatDuration(pos)),
                Expanded(
                  child: Slider(
                    value: pos,
                    max: dur > 0 ? dur : 1,
                    onChanged: (v) => session.seek(v),
                  ),
                ),
                Text(formatDuration(dur)),
              ],
            ),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceEvenly,
              children: [
                IconButton(
                  tooltip: '上一句',
                  icon: const Icon(Icons.skip_previous),
                  onPressed: () => session.seekToLine(li - 1),
                ),
                IconButton(
                  tooltip: '重唱这一句',
                  icon: const Icon(Icons.replay),
                  onPressed: () => session.seekToLine(li),
                ),
                FilledButton(
                  onPressed: onPlay,
                  style: FilledButton.styleFrom(shape: const CircleBorder(), padding: const EdgeInsets.all(18)),
                  child: Icon(session.isPlaying ? Icons.pause : Icons.play_arrow, size: 32),
                ),
                IconButton(
                  tooltip: '下一句',
                  icon: const Icon(Icons.skip_next),
                  onPressed: () => session.seekToLine(li + 1),
                ),
                IconButton(
                  tooltip: session.loopLine == null ? '单句循环' : '取消循环',
                  isSelected: session.loopLine != null,
                  icon: const Icon(Icons.repeat_one),
                  onPressed: () => session.setLoopLine(session.loopLine == null ? li : null),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

class _MixSheet extends StatefulWidget {
  const _MixSheet({required this.session});
  final PracticeSession session;

  @override
  State<_MixSheet> createState() => _MixSheetState();
}

class _MixSheetState extends State<_MixSheet> {
  @override
  Widget build(BuildContext context) {
    final s = widget.session.settings;
    Future<void> set(void Function() change) async {
      await s.update((_) => change());
      widget.session.applyMix();
      setState(() {});
    }

    return SafeArea(
      child: ListView(
        shrinkWrap: true,
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 16),
        children: [
          Text('伴奏音量 ${(s.accompanimentVolume * 100).round()}%'),
          Slider(value: s.accompanimentVolume, onChanged: (v) => set(() => s.accompanimentVolume = v)),
          Text('原唱人声（导唱）音量 ${(s.guideVocalVolume * 100).round()}%'),
          Slider(value: s.guideVocalVolume, onChanged: (v) => set(() => s.guideVocalVolume = v)),
          Text('延迟补偿 ${s.latencyOffsetMs} ms（系统测得 ${(widget.session.latency * 1000).round()} ms）'),
          Slider(
            value: s.latencyOffsetMs.toDouble(),
            min: -300,
            max: 300,
            divisions: 60,
            onChanged: (v) => set(() => s.latencyOffsetMs = v.round()),
          ),
          Text('音准容差 ±${s.toleranceCents} 音分'),
          Slider(
            value: s.toleranceCents.toDouble(),
            min: 20,
            max: 100,
            divisions: 16,
            onChanged: (v) => set(() => s.toleranceCents = v.round()),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('忽略八度（男女声互唱）'),
            value: s.octaveTolerant,
            onChanged: (v) => set(() => s.octaveTolerant = v),
          ),
          const Text('提示：戴耳机练习，麦克风就不会录到伴奏，音高检测更准。', style: TextStyle(fontSize: 12)),
        ],
      ),
    );
  }
}
