import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../app/test_build.dart';
import '../library/song.dart';
import '../practice/practice_session.dart';
import 'lyrics_style.dart';
import 'pitch_graph.dart';
import 'results_sheet.dart';
import 'theme.dart';
import 'widgets.dart';

/// The practice screen: the melody scrolls under a playhead on score paper
/// while the singer's live YIN pitch is traced over it.
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

class _PracticePageState extends State<PracticePage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final PracticeSession _session;
  late final Ticker _ticker;
  final _started = Stopwatch();
  bool _shownResults = false;
  bool _init = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker((_) => _session.tick());
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_init) return;
    _init = true;
    final services = AppScope.of(context);
    _session =
        widget.sessionFactory?.call(context) ??
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
    final lifecycle = WidgetsBinding.instance.lifecycleState;
    if (lifecycle != null && lifecycle != AppLifecycleState.resumed) {
      _session.suspend();
    }
    _session.start().then((_) {
      if (mounted) _ticker.start();
    });
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_init) return;
    if (state == AppLifecycleState.resumed) {
      _session.resume();
    } else {
      _started.stop();
      _session.suspend();
    }
  }

  void _onSession() {
    if (!_session.isPlaying) _started.stop();
    if (_session.finished && !_shownResults) {
      _shownResults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showResults(saveRecord: true));
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
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
    if (saveRecord) {
      record = await _session.save(elapsedSeconds: _started.elapsed.inMilliseconds / 1000);
    }
    if (!mounted) return;
    final action = await showModalBottomSheet<ResultsAction>(
      context: context,
      isScrollControlled: true,
      builder: (_) => ResultsSheet(
        scorer: _session.scorer,
        record: record,
        contour: widget.contour,
        canListen: (line) => _session.canListenBack(line: line),
      ),
    );
    _shownResults = false;
    _session.finished = false;
    switch (action) {
      case LoopLineAction(:final line):
        _session.stopListening();
        _session.setLoopLine(line);
        _session.seekToLine(line);
      case ListenBackAction(:final line):
        _session.listenBack(line: line);
      case ListenOriginalAction(:final line):
        _session.listenOriginal(line: line);
      case null:
        break;
    }
  }

  void _togglePlay() {
    _session.togglePlay();
    if (_session.isPlaying && !_session.reviewing) _started.start();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.meta.title, maxLines: 1, overflow: TextOverflow.ellipsis),
        actions: [
          IconButton(
            tooltip: '练习设置',
            icon: const Icon(Icons.tune_rounded),
            onPressed: () => showModalBottomSheet<void>(
              context: context,
              isScrollControlled: true,
              builder: (_) => _MixSheet(session: _session),
            ),
          ),
          IconButton(
            tooltip: '查看评分',
            icon: const Icon(Icons.insights_rounded),
            onPressed: () => _showResults(saveRecord: true),
          ),
          const SizedBox(width: 4),
        ],
      ),
      body: ListenableBuilder(
        listenable: _session,
        builder: (context, _) {
          if (_session.error != null) {
            return Padding(
              padding: const EdgeInsets.all(28),
              child: Text(_session.error!, style: context.type.bodyLarge),
            );
          }
          if (!_session.started) {
            return Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const CircularProgressIndicator(),
                  const SizedBox(height: 16),
                  Text('正在载入伴奏和原唱', style: context.type.bodyMedium),
                ],
              ),
            );
          }
          return Column(
            children: [
              if (_session.reviewing) _ReviewBar(session: _session),
              if (_session.pauseReason != null)
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 6),
                  child: Text(_session.pauseReason!, style: context.type.bodySmall),
                ),
              _LiveMeter(session: _session),
              Expanded(
                child: _Stage(session: _session, contour: widget.contour),
              ),
              _Lyrics(session: _session),
              _Transport(session: _session, onPlay: _togglePlay),
            ],
          );
        },
      ),
    );
  }
}

/// Shown while listening to the take or to the original singer.
class _ReviewBar extends StatelessWidget {
  const _ReviewBar({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final original = session.listening == ListenKind.original;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 0, 8, 4),
      child: Row(
        children: [
          Icon(original ? Icons.record_voice_over_rounded : Icons.headphones_rounded, size: 18, color: p.ink),
          const SizedBox(width: 8),
          Expanded(child: Text(original ? '正在听原唱，听完回到这一句开头' : '正在回听你唱的，原唱已静音', style: context.type.bodyMedium)),
          TextButton(onPressed: session.stopListening, child: const Text('回到练习')),
        ],
      ),
    );
  }
}

/// Target note, sung note and a cents meter, readable at arm's length.
class _LiveMeter extends StatelessWidget {
  const _LiveMeter({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final s = session.lastVoiced;
    final current = session.reference.noteAt(session.position);
    final target = current ?? session.reference.nextNoteAfter(session.position);
    // Listening back: what was sung at this moment of the take.
    final recorded = session.reviewPoint;
    final reviewing = session.reviewing;
    final fresh = reviewing
        ? recorded != null && recorded.midi > 0
        : s != null && session.isPlaying && session.clockTime - s.pitch.clockTime < 0.5;
    final sungMidi = reviewing ? recorded?.midi : s?.pitch.midi;
    final cents = !fresh ? null : (reviewing ? recorded!.cents : s!.deviationCents);
    String verdict = '';
    Color verdictColor = p.inkFaint;
    final tol = session.settings.toleranceCents.toDouble();
    if (cents != null) {
      final c = cents.round();
      verdict = c.abs() <= tol ? '准' : (c > 0 ? '高了 $c 音分' : '低了 ${-c} 音分');
      verdictColor = p.deviation(cents, tolerance: tol);
    }
    final big = TextStyle(fontSize: 26, fontWeight: FontWeight.w500, height: 1.15, color: p.ink, fontFeatures: tabular);
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 8),
      child: Column(
        children: [
          Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              _NoteReadout(
                label: current != null || target == null ? '原唱' : '下一个',
                value: noteLabel(target?.midi),
                style: current == null ? big.copyWith(color: p.inkFaint) : big,
              ),
              const Spacer(),
              Text(verdict, style: context.type.titleSmall?.copyWith(color: verdictColor)),
              const Spacer(),
              _NoteReadout(label: '你', value: fresh ? noteLabel(sungMidi) : '–', style: big, alignEnd: true),
            ],
          ),
          const SizedBox(height: 6),
          PitchMeter(cents: cents, tolerance: tol),
          Row(
            children: [
              Text('低', style: context.type.labelSmall?.copyWith(color: p.azurite)),
              const Spacer(),
              Text('高', style: context.type.labelSmall?.copyWith(color: p.cinnabar)),
            ],
          ),
        ],
      ),
    );
  }
}

class _NoteReadout extends StatelessWidget {
  const _NoteReadout({required this.label, required this.value, this.style, this.alignEnd = false});
  final String label;
  final String value;
  final TextStyle? style;
  final bool alignEnd;

  @override
  Widget build(BuildContext context) => Column(
    crossAxisAlignment: alignEnd ? CrossAxisAlignment.end : CrossAxisAlignment.start,
    children: [
      Text(label, style: context.type.labelMedium),
      Text(value, style: style),
    ],
  );
}

class _Stage extends StatelessWidget {
  const _Stage({required this.session, this.contour});
  final PracticeSession session;
  final PitchTrack? contour;

  @override
  Widget build(BuildContext context) {
    final ph = session.position;
    final span = session.settings.practiceWindowSeconds;
    final t0 = ph - span * 0.3, t1 = ph + span * 0.7;
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
    return CustomPaint(
      size: Size.infinite,
      painter: PitchGraphPainter(
        reference: session.reference,
        contour: contour,
        t0: t0,
        t1: t1,
        midiLo: a,
        midiHi: b + 1.5,
        style: PitchGraphStyle.of(
          context,
          tolerance: session.settings.toleranceCents.toDouble(),
          language: session.reference.language,
        ),
        user: session.displayPoints,
        playhead: ph,
        tokenScores: session.tokenScores(),
        glyphSize: 16,
        live: true,
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
    if (li < 0) return const SizedBox(height: 84);
    final line = ref.lines[li];
    final next = li + 1 < ref.lines.length ? ref.lines[li + 1] : null;
    final ph = session.position;
    final p = context.yt;
    final scores = session.tokenScores();
    final language = ref.language;
    final base = lyricsStyle(context.type.headlineSmall!.copyWith(fontWeight: FontWeight.w500, height: 1.2), language)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text.rich(
            TextSpan(
              children: [
                for (final (k, t) in line.tokens.indexed)
                  TextSpan(
                    text: '${tokenGap(k > 0 ? line.tokens[k - 1] : null, t)}${t.text}',
                    style: base.copyWith(
                      color: scores[t] != null ? p.score(scores[t]!) : (ph >= t.start ? p.ink : p.inkFaint),
                      fontWeight: ph >= t.start && ph < t.end ? FontWeight.w800 : FontWeight.w500,
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 6),
          Text(next?.text ?? ' ', style: lyricsStyle(context.type.bodyMedium?.copyWith(color: p.inkFaint), language)),
          const SizedBox(height: 4),
          // How does this line go? The original singer, then sing it.
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                visualDensity: VisualDensity.compact,
              ),
              onPressed: session.reviewing ? null : () => session.listenOriginal(line: li),
              icon: const Icon(Icons.record_voice_over_rounded, size: 18),
              label: const Text('听这句原唱'),
            ),
          ),
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
    final p = context.yt;
    final dur = session.duration;
    final pos = session.position.clamp(0, dur > 0 ? dur : 1).toDouble();
    final li = session.currentLine;
    final looping = session.loopLine != null;
    // Listening back plays one take; moving between lines is for practising.
    final practising = !session.reviewing;
    return SafeArea(
      top: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 10),
        child: Column(
          children: [
            _Timeline(
              position: pos,
              duration: dur,
              lineStarts: [for (final l in session.reference.lines) l.start],
              loop: looping ? session.reference.lines[session.loopLine!] : null,
              onSeek: session.seek,
            ),
            Row(
              children: [
                Text(clock(pos), style: context.type.labelSmall?.copyWith(fontFeatures: tabular)),
                const Spacer(),
                Text(clock(dur), style: context.type.labelSmall?.copyWith(fontFeatures: tabular)),
              ],
            ),
            const SizedBox(height: 4),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                IconButton(
                  tooltip: '上一句',
                  icon: const Icon(Icons.skip_previous_rounded, size: 30),
                  onPressed: practising ? () => session.seekToLine(li - 1) : null,
                ),
                IconButton(
                  tooltip: '重唱这一句',
                  icon: const Icon(Icons.replay_rounded, size: 28),
                  onPressed: practising ? () => session.seekToLine(li) : null,
                ),
                SizedBox(
                  width: 72,
                  height: 72,
                  child: FilledButton(
                    onPressed: onPlay,
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    child: Icon(session.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 38),
                  ),
                ),
                IconButton(
                  tooltip: '下一句',
                  icon: const Icon(Icons.skip_next_rounded, size: 30),
                  onPressed: practising ? () => session.seekToLine(li + 1) : null,
                ),
                IconButton(
                  tooltip: looping ? '取消单句循环' : '单句循环',
                  icon: Icon(
                    Icons.repeat_one_rounded,
                    size: 28,
                    color: !practising ? p.inkFaint : (looping ? p.malachite : p.ink),
                  ),
                  onPressed: practising ? () => session.setLoopLine(looping ? null : li) : null,
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

/// Progress line with a tick at the start of every lyric line.
class _Timeline extends StatelessWidget {
  const _Timeline({
    required this.position,
    required this.duration,
    required this.lineStarts,
    required this.onSeek,
    this.loop,
  });
  final double position;
  final double duration;
  final List<double> lineStarts;
  final RefLine? loop;
  final void Function(double) onSeek;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    return LayoutBuilder(
      builder: (context, c) {
        void seekAt(double dx) => onSeek((dx / c.maxWidth).clamp(0.0, 1.0) * duration);
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) => seekAt(d.localPosition.dx),
          onHorizontalDragUpdate: (d) => seekAt(d.localPosition.dx),
          child: SizedBox(
            height: 26,
            child: CustomPaint(size: Size.infinite, painter: _TimelinePainter(position, duration, lineStarts, loop, p)),
          ),
        );
      },
    );
  }
}

class _TimelinePainter extends CustomPainter {
  _TimelinePainter(this.position, this.duration, this.lineStarts, this.loop, this.p);
  final double position;
  final double duration;
  final List<double> lineStarts;
  final RefLine? loop;
  final YtPalette p;

  @override
  void paint(Canvas canvas, Size size) {
    if (duration <= 0) return;
    final cy = size.height / 2;
    double x(double t) => (t / duration).clamp(0.0, 1.0) * size.width;
    canvas.drawLine(
      Offset(0, cy),
      Offset(size.width, cy),
      Paint()
        ..color = p.staffStrong
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    final l = loop;
    if (l != null) {
      canvas.drawLine(
        Offset(x(l.start - 1.2), cy),
        Offset(x(l.end + 0.6), cy),
        Paint()
          ..color = p.malachite.withValues(alpha: 0.5)
          ..strokeWidth = 7
          ..strokeCap = StrokeCap.round,
      );
    }
    canvas.drawLine(
      Offset(0, cy),
      Offset(x(position), cy),
      Paint()
        ..color = p.ink
        ..strokeWidth = 3
        ..strokeCap = StrokeCap.round,
    );
    final tick = Paint()
      ..color = p.paper.withValues(alpha: 0.7)
      ..strokeWidth = 1;
    for (final s in lineStarts) {
      canvas.drawLine(Offset(x(s), cy - 1.5), Offset(x(s), cy + 1.5), tick);
    }
    canvas.drawCircle(Offset(x(position), cy), 6, Paint()..color = p.ink);
  }

  @override
  bool shouldRepaint(_TimelinePainter old) => old.position != position || old.loop != loop || old.p != p;
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

    Widget slider(String title, String value, Widget slider) => Padding(
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
          slider,
        ],
      ),
    );

    return SafeArea(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('练习设置', style: context.type.headlineSmall),
            slider(
              '伴奏',
              '${(s.accompanimentVolume * 100).round()}%',
              Slider(value: s.accompanimentVolume, onChanged: (v) => set(() => s.accompanimentVolume = v)),
            ),
            slider(
              '原唱导唱',
              '${(s.guideVocalVolume * 100).round()}%',
              Slider(value: s.guideVocalVolume, onChanged: (v) => set(() => s.guideVocalVolume = v)),
            ),
            slider(
              '音准容差',
              '±${s.toleranceCents} 音分',
              Slider(
                value: s.toleranceCents.toDouble(),
                min: 20,
                max: 100,
                divisions: 16,
                onChanged: (v) => set(() => s.toleranceCents = v.round()),
              ),
            ),
            slider(
              '延迟补偿',
              '${s.latencyOffsetMs >= 0 ? '+' : ''}${s.latencyOffsetMs} ms',
              Slider(
                value: s.latencyOffsetMs.toDouble(),
                min: -300,
                max: 300,
                divisions: 60,
                onChanged: (v) => set(() => s.latencyOffsetMs = v.round()),
              ),
            ),
            Text(
              '系统测得的延迟 ${(widget.session.latency * 1000).round()} ms。你的音高线总比原唱靠右时，把补偿调大。',
              style: context.type.bodySmall,
            ),
            const SizedBox(height: 6),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('忽略八度'),
              subtitle: const Text('男声唱女声的歌（或反过来）时打开'),
              value: s.octaveTolerant,
              onChanged: (v) => set(() => s.octaveTolerant = v),
            ),
            Text('戴耳机练习：外放时麦克风会录到伴奏，音高会测不准。', style: context.type.bodySmall),
            // Test builds only: what the audio session reported, to explain
            // a pause nobody asked for.
            if (isTestBuild) ...[
              const SizedBox(height: 16),
              Text('测试版：最近的音频事件', style: context.type.titleSmall),
              const SizedBox(height: 4),
              SelectableText(
                _audioLog(),
                style: context.type.bodySmall?.copyWith(fontFamily: 'Menlo', fontFamilyFallback: const ['monospace']),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

String _audioLog() {
  try {
    final lines = NativeAudio.audioEventLog;
    return lines.isEmpty ? '（还没有）' : lines.join('\n');
  } catch (_) {
    return '（读不到）';
  }
}
