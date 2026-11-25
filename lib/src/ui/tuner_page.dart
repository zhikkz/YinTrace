import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/microphone.dart';
import '../app/screen_awake.dart';
import '../app/services.dart';
import '../app/settings.dart';
import '../dsp/pitch.dart';
import '../practice/live_pitch.dart';
import '../practice/scoring.dart';
import 'pitch_graph.dart';
import 'theme.dart';
import 'widgets.dart';

/// Free practice: a live pitch monitor. The trace is coloured by how far
/// the voice is from the nearest semitone.
class TunerPage extends StatefulWidget {
  const TunerPage({super.key, this.engineFactory});

  final PracticeEngine Function()? engineFactory;

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with SingleTickerProviderStateMixin, WidgetsBindingObserver {
  PracticeEngine? _engine;
  LivePitchTracker? _tracker;
  late AppSettings _settings;
  late final Ticker _ticker;
  final _points = <UserPoint>[];
  LivePitch? _last;
  double _now = 0;
  String? _error;
  double _lo = 52, _hi = 76;
  bool _paused = false;
  bool _starting = false;
  final _monitor = ValueNotifier((available: false, enabled: false));

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

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _settings = AppScope.of(context).settings;
  }

  Future<void> _start() async {
    if (_starting || !mounted) return;
    _starting = true;
    try {
      final permission = await NativeAudio.requestMicPermission();
      if (!mounted) return;
      if (permission != MicPermission.granted) {
        setState(() => _error = microphoneDeniedMessage);
        return;
      }
      NativeAudio.configureSession(record: true, measurement: _settings.measurementMode);
      // The wired route is supported on iOS. Keep the capture-only device
      // elsewhere so a playback device is not required for pitch tracking.
      final e =
          widget.engineFactory?.call() ??
          PracticeEngine.create(mode: Platform.isIOS ? EngineMode.duplex : EngineMode.capture);
      _engine = e;
      e.setMonitorWhileCapturing(true);
      _tracker = LivePitchTracker(
        sampleRate: e.sampleRate,
        options: LivePitchOptions(gateDb: _settings.micGateDb),
      );
      if (!_paused) {
        e.start();
        _awake.hold();
      }
      _applyMonitor();
      _ticker.start();
    } catch (err) {
      if (mounted) setState(() => _error = '麦克风打不开：$err');
    } finally {
      _starting = false;
    }
  }

  void _applyMonitor({bool? enabled}) {
    final e = _engine;
    final available = e?.monitorAvailable ?? false;
    final on = available && (enabled ?? _monitor.value.enabled);
    if (on != _monitor.value.enabled && e != null && !_paused) {
      // Monitoring runs in measurement mode (see _measurement).
      try {
        NativeAudio.configureSession(record: true, measurement: _settings.measurementMode || on);
      } catch (_) {}
    }
    e?.setMonitorGain(on && !_paused ? _settings.monitorGain : 0);
    _monitor.value = (available: available, enabled: on);
  }

  /// Measurement mode keeps iOS's voice processing (AGC, the built-in
  /// microphone's processing delay) out of the input, also while monitoring
  /// (wired headphones only, where its quieter speaker output does not
  /// matter).
  bool get _measurement => _settings.measurementMode || _monitor.value.enabled;

  void _pause({bool deviceLost = false}) {
    _awake.release();
    _engine?.stop();
    _engine?.flushCapture();
    _tracker?.reset();
    if (mounted) {
      setState(() {
        _paused = true;
        _last = null;
      });
      _applyMonitor(enabled: deviceLost ? false : null);
    }
  }

  Future<void> _continue() async {
    setState(() {
      _paused = false;
      _error = null;
    });
    final e = _engine;
    if (e == null) {
      await _start();
      return;
    }
    try {
      NativeAudio.configureSession(record: true, measurement: _measurement);
      final deviceLost = e.takeAudioEvents() & AudioEvents.deviceLost != 0;
      e.flushCapture();
      _tracker?.reset();
      e.start();
      _applyMonitor(enabled: deviceLost ? false : null);
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
    if (e == null || tr == null) return;
    final events = e.takeAudioEvents();
    final deviceLost = events & AudioEvents.deviceLost != 0;
    if (!_paused && events & AudioEvents.silencing != 0) {
      _pause(deviceLost: deviceLost);
      return;
    }
    if (deviceLost || events & AudioEvents.routeChanged != 0) {
      _applyMonitor(enabled: deviceLost ? false : null);
    }
    if (_paused) return;
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

  Future<void> _showMonitorSettings() async {
    final settings = _settings;
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: Listenable.merge([_monitor, settings]),
        builder: (context, _) {
          final (:available, :enabled) = _monitor.value;
          return SafeArea(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(20, 12, 20, 16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  SwitchListTile(
                    contentPadding: EdgeInsets.zero,
                    title: const Text('耳返（有线耳机）'),
                    subtitle: Text(
                      available ? '练习时实时听见自己，暂停时静音；打开时关掉系统的人声处理，延迟更低' : '请连接有线耳机、耳机转接头或 USB 耳机',
                    ),
                    value: enabled,
                    onChanged: available ? (value) => _applyMonitor(enabled: value) : null,
                  ),
                  Text('耳返音量 ${(settings.monitorLevel * 100).round()}%'),
                  Slider(
                    value: settings.monitorLevel,
                    onChanged: enabled
                        ? (value) {
                            settings.change((s) => s.monitorLevel = value);
                            _applyMonitor();
                          }
                        : null,
                    onChangeEnd: (_) => settings.save(),
                  ),
                  Text('建议从 50% 左右开始：轻声会被自动托起，大声会被压住。听到啸叫时把耳机戴好或调低耳返音量。', style: context.type.bodySmall),
                ],
              ),
            ),
          );
        },
      ),
    );
    await settings.save();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker.dispose();
    _monitor.dispose();
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
      appBar: AppBar(
        title: const Text('自由练习'),
        actions: [
          IconButton(
            icon: const Icon(Icons.headphones_rounded),
            tooltip: '耳返设置',
            onPressed: _error == null ? _showMonitorSettings : null,
          ),
        ],
      ),
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
