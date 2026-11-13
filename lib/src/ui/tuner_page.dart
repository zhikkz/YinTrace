import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/services.dart';
import '../dsp/pitch.dart';
import '../practice/live_pitch.dart';
import '../practice/scoring.dart';
import 'pitch_graph.dart';

/// Free practice: real-time YIN pitch with a scrolling trail and a cents
/// meter, like a pitch monitor / tuner.
class TunerPage extends StatefulWidget {
  const TunerPage({super.key});

  @override
  State<TunerPage> createState() => _TunerPageState();
}

class _TunerPageState extends State<TunerPage> with SingleTickerProviderStateMixin {
  PracticeEngine? _engine;
  LivePitchTracker? _tracker;
  late final Ticker _ticker;
  final _points = <UserPoint>[];
  LivePitch? _last;
  double _now = 0;
  String? _error;
  double _lo = 52, _hi = 76;

  @override
  void initState() {
    super.initState();
    _ticker = createTicker(_tick);
    WidgetsBinding.instance.addPostFrameCallback((_) => _start());
  }

  Future<void> _start() async {
    final settings = AppScope.of(context).settings;
    try {
      if (await NativeAudio.requestMicPermission() == MicPermission.denied) {
        setState(() => _error = '没有麦克风权限：请在系统设置中允许 YinTrace 使用麦克风');
        return;
      }
      NativeAudio.configureSession(record: true, measurement: settings.measurementMode);
      final e = PracticeEngine.create(mode: EngineMode.capture);
      _engine = e;
      _tracker = LivePitchTracker(sampleRate: e.sampleRate, options: LivePitchOptions(gateDb: settings.micGateDb));
      e.start();
      _ticker.start();
    } catch (err) {
      setState(() => _error = '无法打开麦克风：$err');
    }
  }

  void _tick(Duration _) {
    final e = _engine, tr = _tracker;
    if (e == null || tr == null) return;
    var changed = false;
    for (final b in e.readCapture()) {
      for (final p in tr.addBlock(b.samples, b.songFrame, b.clockFrame, false)) {
        _points.add(UserPoint(p.clockTime, p.midi, PitchVerdict.noReference));
        _now = p.clockTime;
        if (p.voiced) {
          _last = p;
          // Follow the voice vertically.
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
    _ticker.dispose();
    final e = _engine;
    if (e != null) {
      e.stop();
      e.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final last = _last;
    final recent = last != null && _now - last.clockTime < 0.4;
    final cents = last == null ? 0.0 : (last.midi - last.midi.roundToDouble()) * 100;
    return Scaffold(
      appBar: AppBar(title: const Text('自由练习')),
      body: _error != null
          ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(_error!)))
          : Column(
              children: [
                const SizedBox(height: 12),
                Text(recent ? noteName(last.midi) : '—',
                    style: theme.textTheme.displayLarge?.copyWith(fontWeight: FontWeight.w700)),
                Text(recent ? '${last.frequency.toStringAsFixed(1)} Hz · 简谱 ${solfegeName(last.midi)}' : '对着麦克风唱一个音',
                    style: theme.textTheme.titleMedium),
                const SizedBox(height: 12),
                _CentsMeter(cents: recent ? cents : null),
                const SizedBox(height: 12),
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(8, 0, 8, 16),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CustomPaint(
                        size: Size.infinite,
                        painter: PitchGraphPainter(
                          reference: null,
                          t0: _now - 6,
                          t1: _now + 0.3,
                          midiLo: _lo,
                          midiHi: _hi,
                          colors: PitchGraphColors.of(context),
                          user: _points,
                          playhead: _now,
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}

class _CentsMeter extends StatelessWidget {
  const _CentsMeter({required this.cents});
  final double? cents;

  @override
  Widget build(BuildContext context) {
    final colors = PitchGraphColors.of(context);
    final c = cents;
    final color = c == null
        ? Theme.of(context).colorScheme.outline
        : (c.abs() <= 15 ? colors.great : (c.abs() <= 30 ? colors.ok : colors.off));
    return SizedBox(
      height: 44,
      width: 300,
      child: CustomPaint(
        painter: _MeterPainter(c, color, Theme.of(context).colorScheme.onSurface),
        child: Center(
          child: Padding(
            padding: const EdgeInsets.only(top: 26),
            child: Text(c == null ? '' : '${c >= 0 ? '+' : ''}${c.round()} 音分',
                style: TextStyle(color: color, fontWeight: FontWeight.w600)),
          ),
        ),
      ),
    );
  }
}

class _MeterPainter extends CustomPainter {
  _MeterPainter(this.cents, this.color, this.ink);
  final double? cents;
  final Color color;
  final Color ink;

  @override
  void paint(Canvas canvas, Size size) {
    final y = 12.0;
    final p = Paint()
      ..color = ink.withValues(alpha: 0.25)
      ..strokeWidth = 2;
    canvas.drawLine(Offset(0, y), Offset(size.width, y), p);
    for (var k = -50; k <= 50; k += 10) {
      final x = size.width / 2 + k / 50 * size.width / 2;
      canvas.drawLine(Offset(x, y - (k == 0 ? 10 : 5)), Offset(x, y + (k == 0 ? 10 : 5)), p);
    }
    final c = cents;
    if (c != null) {
      final x = size.width / 2 + c.clamp(-50, 50) / 50 * size.width / 2;
      canvas.drawCircle(Offset(x, y), 8, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_MeterPainter old) => old.cents != cents || old.color != color;
}
