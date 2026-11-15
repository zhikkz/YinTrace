import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/screen_awake.dart';
import '../app/services.dart';
import '../dsp/pitch.dart';
import '../practice/live_pitch.dart';
import '../practice/scoring.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

/// Free practice: a live pitch monitor. The trace is coloured by how far
/// the voice is from the nearest semitone.
class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  PracticeEngine? _engine;
  LivePitchTracker? _tracker;
  late final Ticker _ticker;
  final _points = <UserPoint>[];
  LivePitch? _last;
  double _now = 0;
  String? _error;
  double _lo = 52, _hi = 76;
  bool _paused = false;
  bool _starting = false;

  /// Held while the microphone is listening: a long note is sung without
  /// touching the screen, and a locked phone stops the capture.
  final _awake = ScreenAwake();

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _ticker = createTicker(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    if (_starting || !mounted) return;
    _starting = true;
    final settings = AppScope.of(context).settings;
    try {
      final permission = await NativeAudio.requestMicPermission();
      if (!mounted) return;
      if (permission != MicPermission.granted) {
        setState(() => _error = '没有麦克风权限。到 系统设置 → 隐私与安全性 → 麦克风，打开 YinTrace。');
        return;
      }
      NativeAudio.configureSession(record: true, measurement: settings.measurementMode);
      final e = PracticeEngine.create(mode: EngineMode.capture);
      _engine = e;
      _tracker = LivePitchTracker(
        sampleRate: e.sampleRate,
        options: LivePitchOptions(gateDb: settings.micGateDb),
      );
      if (!_paused) {
        e.start();
        _awake.hold();
      }
      _ticker.start();
    } catch (err) {
      if (mounted) setState(() => _error = '麦克风打不开：$err');
    } finally {
      _starting = false;
    }
  }

  void _pause() {
    _awake.release();
    _engine?.stop();
    _engine?.flushCapture();
    _tracker?.reset();
    if (mounted) {
      setState(() {
        _paused = true;
        _last = null;
      });
    }
  }

  Future<void> _continue() async {
    setState(() {
      _paused = false;
      _error = null;
    });
    if (_engine == null) {
      await _start();
      return;
    }
    try {
      NativeAudio.configureSession(record: true, measurement: AppScope.of(context).settings.measurementMode);
      _engine!.takeAudioEvents();
      _engine!.flushCapture();
      _tracker?.reset();
      _engine!.start();
      _awake.hold();
    } catch (_) {
      _pause();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state != AppLifecycleState.resumed) _pause();
  }

  void _tick(Duration _) {
    final e = _engine, tr = _tracker;
    if (e == null || tr == null || _paused) return;
    if (e.takeAudioEvents() & AudioEvents.silencing != 0) {
      _pause();
      return;
    }
    var changed = false;
    for (final b in e.readCapture()) {
      for (final p in tr.addBlock(b.samples, b.songFrame, b.clockFrame, false)) {
        final cents = p.voiced ? (p.midi - p.midi.roundToDouble()) * 100 : null;
        _points.add(UserPoint(p.clockTime, p.midi, PitchVerdict.noReference, cents));
        _now = p.clockTime;
        if (p.voiced) {
          _last = p;
          if (p.midi < _lo + 2) _lo = p.midi - 2;
          if (p.midi > _hi - 2) _hi = p.midi + 2;
        }
        changed = true;
      }
    }
    if (_points.length > 2000) _points.removeRange(0, _points.length - 1500);
    if (_hi - _lo > 30) {
      final c = _last?.midi ?? (_lo + _hi) / 2;
      _lo = c - 12;
      _hi = c + 12;
    }
    if (changed) setState(() {});
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _awake.release();
    final e = _engine;
    if (e != null) {
      e.stop();
      e.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final last = _last;
    final recent = last != null && _now - last.clockTime < 0.4;
    final cents = recent ? (last.midi - last.midi.roundToDouble()) * 100 : null;
    return Scaffold(
      appBar: AppBar(title: const Text('自由练习')),
      body: _error != null
          ? Padding(
              padding: const EdgeInsets.all(28),
              child: Text(_error!, style: context.type.bodyLarge),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                if (_paused)
                  Padding(
                    padding: const EdgeInsets.all(16),
                    child: Column(
                      children: [
                        const Text('采集已暂停'),
                        FilledButton(onPressed: _continue, child: const Text('继续练习')),
                      ],
                    ),
                  ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 8, 20, 0),
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Text(
                        recent ? noteName(last.midi) : '–',
                        style: context.type.displayLarge?.copyWith(fontSize: 76, fontWeight: FontWeight.w300),
                      ),
                      const SizedBox(width: 14),
                      Padding(
                        padding: const EdgeInsets.only(bottom: 10),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              recent ? '简谱 ${solfegeName(last.midi)}' : '对着麦克风唱一个长音',
                              style: context.type.titleMedium,
                            ),
                            Text(
                              recent ? '${last.frequency.toStringAsFixed(1)} Hz' : '音高会实时画在下面',
                              style: context.type.bodySmall?.copyWith(fontFeatures: tabular),
                            ),
                          ],
                        ),
                      ),
                      const Spacer(),
                      if (cents != null)
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            '${cents >= 0 ? '+' : ''}${cents.round()}',
                            style: context.type.headlineSmall?.copyWith(
                              color: p.deviation(cents, tolerance: 15),
                              fontFeatures: tabular,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 10, 20, 0),
                  child: PitchMeter(cents: cents, tolerance: 15, range: 50),
                ),
                Padding(
                  padding: const EdgeInsets.fromLTRB(20, 0, 20, 8),
                  child: Row(
                    children: [
                      Text('偏低', style: context.type.labelSmall?.copyWith(color: p.azurite)),
                      const Spacer(),
                      Text('±50 音分', style: context.type.labelSmall),
                      const Spacer(),
                      Text('偏高', style: context.type.labelSmall?.copyWith(color: p.cinnabar)),
                    ],
                  ),
                ),
                Expanded(
                  child: CustomPaint(
                    size: Size.infinite,
                    painter: PitchGraphPainter(
                      reference: null,
                      t0: _now - 6,
                      t1: _now + 0.4,
                      midiLo: _lo,
                      midiHi: _hi,
                      style: PitchGraphStyle.of(context, tolerance: 15),
                      user: _points,
                      playhead: _now,
                      live: true,
                    ),
                  ),
                ),
                const SizedBox(height: 16),
              ],
            ),
    );
  }
}
