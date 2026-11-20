import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../app/test_build.dart';
import '../export/recordings.dart';
import '../library/song.dart';
import '../practice/practice_session.dart';
import 'export_page.dart';
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
    this.onLeave,
    this.sessionFactory,
    this.exportPageBuilder,
    this.backgroundWork = true,
  });

  final SongMeta meta;
  final SongReference reference;
  final PitchTrack? contour;
  final int? loopLine;

  /// Called as the page is left, with the save of what was sung in it: the
  /// page below can wait for it before it reads the song's history again.
  final void Function(Future<void> saved)? onLeave;

  /// For tests.
  final PracticeSession Function(BuildContext context)? sessionFactory;
  final Widget Function(String songId, String recordingId)? exportPageBuilder;
  final bool backgroundWork;

  @override
  State<PracticePage> createState() => _PracticePageState();
}

class _PracticePageState extends State<PracticePage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  late final PracticeSession _session;
  late final Ticker _ticker;
  bool _shownResults = false;
  bool _init = false;

  /// The take kept as a recording: (take version, recording id).
  (int, String)? _kept;

  /// The screen stays on for as long as the practice page is open.
  final _awake = ScreenAwake();

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
    _awake.hold();
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
      _session.suspend();
    }
  }

  void _onSession() {
    if (_session.finished && !_shownResults) {
      _shownResults = true;
      WidgetsBinding.instance.addPostFrameCallback((_) => _showResults(saveRecord: true));
    }
  }

  /// Leaving the page keeps what was sung in it: the run goes into the
  /// song's history like when its scores are looked at (one record however
  /// often). Started once, when the page is popped or else disposed.
  Future<void>? _leaving;

  Future<void> _saveOnLeave() => _leaving ??= _session.save().then((_) {}, onError: (_) {});

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _session.removeListener(_onSession);
    unawaited(_saveOnLeave()); // before the engine goes: the scores stay
    _session.dispose();
    _awake.release();
    super.dispose();
  }

  Future<void> _showResults({bool saveRecord = false}) async {
    _session.pause();
    PracticeRecord? record;
    if (saveRecord) {
      try {
        record = await _session.save();
      } catch (e) {
        // The scores are still worth seeing.
        if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没能保存练习记录：$e')));
      }
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
      case ExportTakeAction():
        await _makeTrack();
      case RestartAction():
        _session.restart();
      case ContinueLoopAction():
        _session.stopListening();
        _session.play();
      case WholeSongAction():
        _session.stopListening();
        _session.setLoopLine(null);
      case null:
        break;
    }
  }

  /// Keeps the take as one of the song's recordings, once per version of
  /// it. Returns the recording's id, or null when that failed.
  Future<String?> _keepTake() async {
    final take = _session.take;
    if (take == null || take.isEmpty) return null;
    final kept = _kept;
    if (kept != null && kept.$1 == take.version) return kept.$2;
    final songs = AppScope.of(context).songs;
    unawaited(
      showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (_) => const AlertDialog(
          content: Row(
            children: [
              SizedBox(width: 22, height: 22, child: CircularProgressIndicator(strokeWidth: 2.5)),
              SizedBox(width: 16),
              Text('正在保存录音…'),
            ],
          ),
        ),
      ),
    );
    try {
      final score = _session.scorer.overallScore();
      final r = await keepTake(
        songs,
        widget.meta.id,
        take,
        score: score.isNaN ? null : score,
        background: widget.backgroundWork,
      );
      _kept = (take.version, r.id);
      return r.id;
    } catch (e) {
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('没能保存录音：$e')));
      return null;
    } finally {
      if (mounted) Navigator.of(context).pop();
    }
  }

  /// Keeps the take (once per version of it) and opens 制作成品 for it.
  Future<void> _makeTrack() async {
    final take = _session.take;
    if (take == null || take.isEmpty) return;
    _session.stopListening();
    // The preview needs the audio device: practice waits until it is back.
    _session.suspend(reason: '练习已暂停，点播放继续');
    final id = await _keepTake();
    if (id != null && mounted) {
      await Navigator.of(context).push(
        MaterialPageRoute<void>(
          builder: (_) =>
              widget.exportPageBuilder?.call(widget.meta.id, id) ?? ExportPage(songId: widget.meta.id, recordingId: id),
        ),
      );
    }
    // Practice can go on (also when keeping the take failed).
    if (mounted) _session.resume();
  }

  /// Whether leaving would lose a recording worth keeping: 20 seconds of
  /// singing (a quarter of a song shorter than 80 seconds) not kept yet.
  /// Then leaving asks. What only played, nobody singing, is no recording.
  bool get _takeAtRisk {
    final take = _session.take;
    if (take == null || take.isEmpty) return false;
    final kept = _kept;
    if (kept != null && kept.$1 == take.version) return false;
    return take.voicedSeconds() >= math.min(20.0, widget.meta.duration / 4);
  }

  /// Leaving with a recording that would be lost: keep it, or leave
  /// without it. Dismissing the question stays on the page.
  Future<void> _confirmLeave() async {
    _session.pause();
    final keep = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('保存刚才唱的录音？'),
        content: const Text('录音只在这次练习里，离开就没有了。保存后在歌曲页的“我的录音”里，随时可以做成成品。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('不保存')),
          TextButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('保存')),
        ],
      ),
    );
    if (keep == null || !mounted) return;
    if (keep && await _keepTake() == null) return; // not kept: stay
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    // Rebuilt with the session: leaving asks first only while a recording
    // would be lost; otherwise the page goes back (and swipes back) as usual.
    return ListenableBuilder(
      listenable: _session,
      builder: (context, child) {
        final ask = _takeAtRisk;
        return PopScope(
          canPop: !ask,
          // Runs as the page is popped, before the page below continues:
          // it gets the save to wait for.
          onPopInvokedWithResult: (didPop, _) {
            if (didPop) {
              widget.onLeave?.call(_saveOnLeave());
            } else if (ask) {
              _confirmLeave();
            }
          },
          child: child!,
        );
      },
      child: _scaffold(context),
    );
  }

  Widget _scaffold(BuildContext context) {
    final settings = AppScope.of(context).settings;
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
              useSafeArea: true,
              builder: (_) => _MixSheet(session: _session),
            ),
          ),
          Tooltip(
            message: '查看评分',
            child: TextButton.icon(
              onPressed: () => _showResults(saveRecord: true),
              icon: const Icon(Icons.insights_rounded, size: 20),
              label: const Text('评分'),
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: ListenableBuilder(
        listenable: Listenable.merge([_session, settings]),
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
              if (_session.pauseReason case final reason?)
                _Notice(icon: Icons.pause_circle_outline_rounded, text: reason)
              else if (!settings.headphoneTipSeen)
                _Notice(
                  icon: Icons.headphones_rounded,
                  text: '戴上耳机再唱：外放时麦克风会录到伴奏，音准会测不准。',
                  action: '知道了',
                  onAction: () => settings.update((s) => s.headphoneTipSeen = true),
                ),
              _LiveMeter(session: _session),
              Expanded(
                child: _Stage(session: _session, contour: widget.contour),
              ),
              _Lyrics(session: _session),
              _Transport(session: _session),
            ],
          );
        },
      ),
    );
  }
}

/// A short notice at the top: why practice paused, or a tip.
class _Notice extends StatelessWidget {
  const _Notice({required this.icon, required this.text, this.action, this.onAction});
  final IconData icon;
  final String text;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 6),
      padding: EdgeInsets.fromLTRB(12, 8, action == null ? 12 : 4, 8),
      decoration: BoxDecoration(
        color: p.gamboge.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Row(
        children: [
          Icon(icon, size: 18, color: p.ink),
          const SizedBox(width: 8),
          Expanded(child: Text(text, style: context.type.bodySmall?.copyWith(color: p.ink))),
          if (action != null)
            TextButton(
              onPressed: onAction,
              style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
              child: Text(action!),
            ),
        ],
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
    // Judged only against a note sounding now: between notes the left shows
    // the next one, and "准" next to it would read as a verdict on that.
    final cents = !fresh || current == null ? null : (reviewing ? recorded!.cents : s!.deviationCents);
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

class _Stage extends StatefulWidget {
  const _Stage({required this.session, this.contour});
  final PracticeSession session;
  final PitchTrack? contour;

  @override
  State<_Stage> createState() => _StageState();
}

class _StageState extends State<_Stage> {
  /// Keep the singer's pitch range through a short gap between lines.
  static const _pitchRangeHoldSeconds = 4.0;

  final _axis = PitchAxisFollower();
  double? _dragSeconds;

  void _finishDrag({required bool canceled}) {
    if (_dragSeconds == null) return;
    _dragSeconds = null;
    if (canceled) {
      widget.session.cancelScrub();
    } else {
      widget.session.endScrub();
    }
  }

  @override
  Widget build(BuildContext context) {
    final session = widget.session;
    final contour = widget.contour;
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
    final user = session.displayPoints;
    // Keep both voices on the same axis, and let recent pitches keep their
    // space for a few seconds after the trail scrolls off the graph.
    if (steadyPitchRange(user, t0 - _pitchRangeHoldSeconds, t1) case (final a, final b)) {
      lo = math.min(lo, a);
      hi = math.max(hi, b);
    }
    final playing = session.isPlaying;
    final live = playing && !session.reviewing;
    final playbackPoint = playing ? session.reviewPoint : null;
    final tokenScores = session.tokenScores();
    final style = PitchGraphStyle.of(
      context,
      tolerance: session.settings.toleranceCents.toDouble(),
      language: session.reference.language,
    );
    const gutter = 30.0;
    final graph = TweenAnimationBuilder<(double, double)>(
      tween: _PitchRangeTween(_axis.follow(lo, hi)),
      duration: const Duration(milliseconds: 280),
      curve: Curves.easeOutCubic,
      builder: (context, range, _) => CustomPaint(
        size: Size.infinite,
        painter: PitchGraphPainter(
          reference: session.reference,
          contour: contour,
          t0: t0,
          t1: t1,
          midiLo: range.$1,
          midiHi: range.$2 + 1.5,
          style: style,
          user: user,
          playhead: ph,
          tokenScores: tokenScores,
          gutter: gutter,
          glyphSize: 16,
          live: live,
          playbackPoint: playbackPoint,
        ),
      ),
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        final plotWidth = constraints.maxWidth - gutter;
        if (plotWidth <= 0) return graph;
        return Listener(
          // Flutter reports a canceled pointer as a drag end once accepted.
          onPointerCancel: (_) => _finishDrag(canceled: true),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            dragStartBehavior: DragStartBehavior.down,
            onHorizontalDragStart: (_) {
              if (session.beginScrub()) _dragSeconds = session.engine!.positionSeconds;
            },
            onHorizontalDragUpdate: (details) {
              final previous = _dragSeconds;
              if (previous == null) return;
              final seconds = previous - details.delta.dx * span / plotWidth;
              final target = seconds.clamp(0.0, session.duration).toDouble();
              _dragSeconds = target;
              session.updateScrub(target);
            },
            onHorizontalDragEnd: (_) => _finishDrag(canceled: false),
            child: graph,
          ),
        );
      },
    );
  }
}

class _PitchRangeTween extends Tween<(double, double)> {
  _PitchRangeTween((double, double) end) : super(end: end);

  @override
  (double, double) lerp(double t) {
    final (lo0, hi0) = begin!;
    final (lo1, hi1) = end!;
    return (lo0 + (lo1 - lo0) * t, hi0 + (hi1 - hi0) * t);
  }
}

/// The last seconds before a line are counted down; 跳过前奏 / 跳过间奏
/// lands there.
const _countdownSeconds = 3.0;

/// A line further away than this can be skipped to.
const _skipFrom = 5.0;

/// Three dots that go out one per second before a line begins.
class _Countdown extends StatelessWidget {
  const _Countdown({required this.seconds});
  final double seconds;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final lit = seconds.ceil().clamp(1, 3);
    return Semantics(
      label: '还有 ${seconds.ceil()} 秒开始唱',
      excludeSemantics: true,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < 3; i++)
            Container(
              width: 8,
              height: 8,
              margin: const EdgeInsets.only(right: 5),
              decoration: BoxDecoration(shape: BoxShape.circle, color: i < lit ? p.ink : p.staffStrong),
            ),
        ],
      ),
    );
  }
}

/// 导唱 on or off: the original singer quietly along, or the accompaniment
/// alone. The volume is in 练习设置.
class _GuideToggle extends StatelessWidget {
  const _GuideToggle({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final s = session.settings;
    final on = s.guideVocalOn;
    return Tooltip(
      message: on ? '原唱小声跟着放，帮你找音；点一下只放伴奏' : '现在只放伴奏；点一下让原唱小声跟着放',
      child: TextButton.icon(
        style: TextButton.styleFrom(
          padding: const EdgeInsets.symmetric(horizontal: 6),
          visualDensity: VisualDensity.compact,
          foregroundColor: on ? p.ink : p.inkSoft,
        ),
        onPressed: session.reviewing
            ? null
            : () {
                s.update((s) => s.guideVocalOn = !on);
                session.applyMix();
              },
        icon: Icon(on ? Icons.music_note_rounded : Icons.music_off_rounded, size: 18),
        label: Text(on ? '导唱：开' : '导唱：关'),
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
    // In an interlude, the line coming up (the transport still works on
    // the line just sung).
    final li = session.shownLine;
    if (li < 0) return const SizedBox(height: 84);
    final line = ref.lines[li];
    final count = ref.lines.length;
    final next = li + 1 < count ? ref.lines[li + 1] : null;
    final ph = session.position;
    final p = context.yt;
    final scores = session.tokenScores();
    final language = ref.language;
    final practising = !session.reviewing;
    final looping = practising && session.loopLine != null;
    // Until the line in focus begins: the intro, an interlude, a lead-in.
    final wait = line.start - ph;
    final passes = looping ? session.scorer.linePasses[li] ?? const <double>[] : const <double>[];
    final base = lyricsStyle(context.type.headlineSmall!.copyWith(fontWeight: FontWeight.w500, height: 1.2), language)!;
    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 4, 20, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Where in the song, and what comes next: a countdown to the
          // line, a way past a long intro, or out of the loop.
          SizedBox(
            height: 34,
            child: Row(
              children: [
                if (looping) ...[
                  Icon(Icons.repeat_one_rounded, size: 16, color: p.ink),
                  const SizedBox(width: 4),
                ],
                Text(
                  looping ? '单句循环 · 第 ${li + 1} / $count 句' : '第 ${li + 1} / $count 句',
                  style: context.type.labelMedium?.copyWith(fontFeatures: tabular, color: looping ? p.ink : null),
                ),
                const SizedBox(width: 10),
                if (practising && session.isPlaying && wait > 0 && wait <= _countdownSeconds) _Countdown(seconds: wait),
                const Spacer(),
                if (looping)
                  TextButton(
                    onPressed: () => session.setLoopLine(null),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    child: const Text('退出循环'),
                  )
                else if (practising && wait > _skipFrom)
                  TextButton.icon(
                    onPressed: () => session.seekToLine(li, leadIn: _countdownSeconds),
                    style: TextButton.styleFrom(visualDensity: VisualDensity.compact),
                    icon: const Icon(Icons.fast_forward_rounded, size: 18),
                    label: Text(li == 0 ? '跳过前奏' : '跳过间奏'),
                  ),
              ],
            ),
          ),
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
          if (line.translation case final translation?)
            Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(translation, maxLines: 1, overflow: TextOverflow.ellipsis, style: context.type.bodySmall),
            ),
          const SizedBox(height: 6),
          // Looping, the line's own progress replaces the line after it.
          if (looping)
            Text(
              passes.isEmpty
                  ? '每唱完一遍，这里记下这一句的得分'
                  : '这一句唱了 ${passes.length} 遍：${passes.length > 5 ? '… ' : ''}'
                        '${passes.skip(math.max(0, passes.length - 5)).map((s) => s.round()).join(' → ')}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: context.type.bodyMedium?.copyWith(fontFeatures: tabular),
            )
          else
            Text(
              next?.text ?? ' ',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: lyricsStyle(context.type.bodyMedium?.copyWith(color: p.inkFaint), language),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              // How does this line go? The original singer, then sing it.
              TextButton.icon(
                style: TextButton.styleFrom(
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  visualDensity: VisualDensity.compact,
                ),
                onPressed: session.reviewing ? null : () => session.listenOriginal(line: li),
                icon: const Icon(Icons.record_voice_over_rounded, size: 18),
                label: const Text('听这句原唱'),
              ),
              const Spacer(),
              // Without an accompaniment the original singer is all there is.
              if (session.hasAccompaniment) _GuideToggle(session: session),
            ],
          ),
        ],
      ),
    );
  }
}

class _Transport extends StatelessWidget {
  const _Transport({required this.session});
  final PracticeSession session;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final dur = session.duration;
    final pos = session.position.clamp(0, dur > 0 ? dur : 1).toDouble();
    final li = session.currentLine;
    final lineCount = session.reference.lines.length;
    final looping = session.loopLine != null;
    // Listening back plays one take; moving between lines is for practising.
    final practising = !session.reviewing && li >= 0;
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
              session: session,
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
                  onPressed: practising && li > 0 ? () => session.seekToLine(li - 1) : null,
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
                    onPressed: session.togglePlay,
                    style: FilledButton.styleFrom(shape: const CircleBorder(), padding: EdgeInsets.zero),
                    child: Icon(session.isPlaying ? Icons.pause_rounded : Icons.play_arrow_rounded, size: 38),
                  ),
                ),
                IconButton(
                  tooltip: '下一句',
                  icon: const Icon(Icons.skip_next_rounded, size: 30),
                  onPressed: practising && li + 1 < lineCount ? () => session.seekToLine(li + 1) : null,
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
class _Timeline extends StatefulWidget {
  const _Timeline({
    required this.position,
    required this.duration,
    required this.lineStarts,
    required this.session,
    this.loop,
  });
  final double position;
  final double duration;
  final List<double> lineStarts;
  final RefLine? loop;
  final PracticeSession session;

  @override
  State<_Timeline> createState() => _TimelineState();
}

class _TimelineState extends State<_Timeline> {
  bool _dragging = false;

  void _finishDrag({required bool canceled}) {
    if (!_dragging) return;
    _dragging = false;
    if (canceled) {
      widget.session.cancelScrub();
    } else {
      widget.session.endScrub();
    }
  }

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    return LayoutBuilder(
      builder: (context, c) {
        double secondsAt(double dx) => (dx / c.maxWidth).clamp(0.0, 1.0) * widget.duration;
        return Listener(
          key: const ValueKey('practice-timeline'),
          onPointerCancel: (_) => _finishDrag(canceled: true),
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTapUp: (d) => widget.session.seek(secondsAt(d.localPosition.dx)),
            onHorizontalDragStart: (d) {
              _dragging = widget.session.beginScrub();
              if (_dragging) widget.session.updateScrub(secondsAt(d.localPosition.dx));
            },
            onHorizontalDragUpdate: (d) {
              if (_dragging) widget.session.updateScrub(secondsAt(d.localPosition.dx));
            },
            onHorizontalDragEnd: (_) => _finishDrag(canceled: false),
            child: SizedBox(
              height: 26,
              child: CustomPaint(
                size: Size.infinite,
                painter: _TimelinePainter(widget.position, widget.duration, widget.lineStarts, widget.loop, p),
              ),
            ),
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
  void initState() {
    super.initState();
    widget.session.addListener(_sessionChanged);
  }

  void _sessionChanged() {
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    widget.session.removeListener(_sessionChanged);
    // A slider that was still being dragged when the sheet closed.
    widget.session.settings.save();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.session.settings;
    Future<void> set(void Function() change) async {
      await s.update((_) => change());
      if (!mounted) return;
      widget.session.applyMix();
      setState(() {});
    }

    // A slider is heard and seen while it is dragged, and saved when it is
    // let go.
    void drag(void Function() change) {
      s.change((_) => change());
      widget.session.applyMix();
      setState(() {});
    }

    void dragEnd(double _) => s.save();

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

    final scrollableOptions = Flexible(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 0, 20, 16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            slider(
              '伴奏',
              '${(s.accompanimentVolume * 100).round()}%',
              Slider(
                value: s.accompanimentVolume,
                onChanged: (v) => drag(() => s.accompanimentVolume = v),
                onChangeEnd: dragEnd,
              ),
            ),
            slider(
              '原唱导唱',
              s.guideVocalOn || !widget.session.hasAccompaniment ? '${(s.guideVocalVolume * 100).round()}%' : '关',
              // Dragging it turns 导唱 on again.
              Slider(
                value: s.guideVocalVolume,
                onChanged: (v) => drag(() {
                  s.guideVocalVolume = v;
                  s.guideVocalOn = true;
                }),
                onChangeEnd: dragEnd,
              ),
            ),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('耳返（有线耳机）'),
              subtitle: Text(
                widget.session.monitorAvailable
                    ? '练习播放时实时听见自己；暂停、听原唱或回听时静音'
                    : '请连接有线耳机、耳机转接头或 USB 耳机；蓝牙和外放不可用',
              ),
              value: widget.session.monitorEnabled,
              onChanged: widget.session.monitorAvailable ? widget.session.setMonitorEnabled : null,
            ),
            slider(
              '耳返音量',
              '${(s.monitorVolume * 100).round()}%',
              Slider(
                value: s.monitorVolume,
                onChanged: widget.session.monitorEnabled ? (v) => drag(() => s.monitorVolume = v) : null,
                onChangeEnd: dragEnd,
              ),
            ),
            slider(
              '音准容差',
              '±${s.toleranceCents} 音分',
              Slider(
                value: s.toleranceCents.toDouble(),
                min: 20,
                max: 100,
                divisions: 16,
                onChanged: (v) => drag(() => s.toleranceCents = v.round()),
                onChangeEnd: dragEnd,
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
                onChanged: (v) => drag(() => s.latencyOffsetMs = v.round()),
                onChangeEnd: dragEnd,
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
    return SafeArea(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            child: Row(
              children: [
                Expanded(child: Text('练习设置', style: context.type.headlineSmall)),
                const CloseButton(),
              ],
            ),
          ),
          scrollableOptions,
        ],
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
