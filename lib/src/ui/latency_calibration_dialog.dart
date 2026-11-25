import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/settings.dart';
import '../practice/latency_calibration.dart';
import '../practice/practice_session.dart';

extension OutputRouteLabel on OutputRoute {
  String get label => switch (this) {
    OutputRoute.speaker => '外放',
    OutputRoute.wired => '有线耳机',
    OutputRoute.usb => 'USB 音频',
    OutputRoute.bluetooth => '蓝牙耳机',
    OutputRoute.airPlay => 'AirPlay',
    OutputRoute.unknown => '未知',
  };
}

String latencyRouteLabel(OutputRoute route, {required bool measurement}) =>
    '${route.label}${measurement ? '（测量模式）' : ''}';

String signedMilliseconds(int ms) => '${ms >= 0 ? '+' : ''}$ms ms';

class LatencyCompensationSlider extends StatelessWidget {
  const LatencyCompensationSlider({
    super.key,
    required this.offsetMs,
    required this.onChanged,
    required this.onChangeEnd,
  });

  final int offsetMs;
  final ValueChanged<double> onChanged;
  final ValueChanged<double> onChangeEnd;

  @override
  Widget build(BuildContext context) => Slider(
    value: offsetMs.toDouble(),
    min: math.min(-500, offsetMs).toDouble(),
    max: math.max(500, offsetMs).toDouble(),
    semanticFormatterCallback: (value) => signedMilliseconds(value.round()),
    onChanged: onChanged,
    onChangeEnd: onChangeEnd,
  );
}

Future<void> showLatencyCalibration(
  BuildContext context, {
  required AppSettings settings,
  required LatencyMeasurer measurer,
  PracticeSession? practice,
}) => showDialog<void>(
  context: context,
  barrierDismissible: false,
  builder: (_) => _LatencyCalibrationDialog(settings: settings, measurer: measurer, practice: practice),
);

class _LatencyCalibrationDialog extends StatefulWidget {
  const _LatencyCalibrationDialog({required this.settings, required this.measurer, this.practice});

  final AppSettings settings;
  final LatencyMeasurer measurer;
  final PracticeSession? practice;

  @override
  State<_LatencyCalibrationDialog> createState() => _LatencyCalibrationDialogState();
}

class _LatencyCalibrationDialogState extends State<_LatencyCalibrationDialog> with WidgetsBindingObserver {
  late LatencyCalibrationMethod _method;
  LatencyCalibrationControl? _control;
  LatencyCalibrationProgress? _progress;
  LatencyCalibrationResult? _result;
  bool _closing = false;
  bool _saving = false;
  bool _saveError = false;

  bool get _measurement => widget.practice?.usesMeasurementMode ?? widget.settings.measurementMode;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _method = switch (widget.measurer.outputRoute) {
      OutputRoute.speaker || OutputRoute.unknown => LatencyCalibrationMethod.automatic,
      _ => LatencyCalibrationMethod.tapAlong,
    };
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    // The first system microphone prompt can make the app inactive before
    // the audio has started. Let it finish while the app stays on screen.
    if (state != AppLifecycleState.resumed && (state != AppLifecycleState.inactive || _progress != null)) {
      _control?.cancel(interrupted: true);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _control?.cancel();
    super.dispose();
  }

  Future<void> _run() async {
    final control = LatencyCalibrationControl();
    final practice = widget.practice;
    final measurement = _measurement;
    setState(() {
      _control = control;
      _progress = null;
      _result = null;
      _saveError = false;
    });
    Future<LatencyCalibrationResult> measure() => widget.measurer.measure(
      _method,
      measurement: measurement,
      control: control,
      onProgress: (progress) {
        if (mounted && !_closing) setState(() => _progress = progress);
      },
    );

    LatencyCalibrationResult result;
    try {
      result = await (practice == null ? measure() : practice.withAudioPausedForCalibration(measure));
    } catch (_) {
      result = LatencyCalibrationFailure.audioUnavailable;
    }
    if (!mounted) return;
    if (_closing) {
      Navigator.of(context).pop();
      return;
    }
    setState(() {
      _control = null;
      _progress = null;
      _result = result;
    });
  }

  void _cancel() {
    final control = _control;
    if (control == null) {
      Navigator.of(context).pop();
    } else {
      setState(() => _closing = true);
      control.cancel();
    }
  }

  Future<void> _use(LatencyCalibrationReading reading) async {
    setState(() {
      _saving = true;
      _saveError = false;
    });
    try {
      await widget.settings.update(
        (s) => s.setLatencyOffset(reading.route, reading.offsetMs, measurement: reading.measurement),
      );
      if (mounted) {
        widget.practice?.applyMix();
        Navigator.of(context).pop();
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          _saving = false;
          _saveError = true;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final reading = _result is LatencyCalibrationReading ? _result as LatencyCalibrationReading : null;
    final failure = _result is LatencyCalibrationFailure ? _result as LatencyCalibrationFailure : null;
    final busy = _control != null;
    final progress = _progress;
    final route = reading?.route ?? progress?.route ?? widget.measurer.outputRoute;
    final routeLabel = latencyRouteLabel(route, measurement: reading?.measurement ?? _measurement);
    final colors = Theme.of(context).colorScheme;

    return PopScope<void>(
      canPop: !busy && !_saving,
      child: AlertDialog(
        title: const Text('测量延迟'),
        scrollable: true,
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(reading == null ? '当前线路：$routeLabel' : '测量线路：$routeLabel'),
            const SizedBox(height: 12),
            if (busy) ...[
              Text(switch ((progress?.fraction, progress?.countdown)) {
                (null, _) => '正在准备麦克风…',
                  (final double fraction, _) when fraction >= 1 => '正在计算延迟…',
                (_, final int count) => '倒数 $count',
                _ when _method == LatencyCalibrationMethod.tapAlong => '跟着每一下节拍唱“嗒”或拍手',
                _ => '正在播放测试音，请保持安静',
              }),
              const SizedBox(height: 12),
              LinearProgressIndicator(value: progress?.fraction),
            ] else if (reading != null) ...[
              Text(
                '测得总延迟 ${(reading.totalSeconds * 1000).round()} ms'
                '（系统报告 ${(reading.systemSeconds * 1000).round()} ms）。'
                '点“使用”将补偿设为 ${signedMilliseconds(reading.offsetMs)}。',
              ),
              if (_saveError) Text('补偿没能保存，请再点一次“使用”。', style: TextStyle(color: colors.error)),
            ] else ...[
              if (failure != null) Text(_failureMessage(failure), style: TextStyle(color: colors.error)),
              RadioGroup<LatencyCalibrationMethod>(
                groupValue: _method,
                onChanged: (method) {
                  if (method != null) setState(() => _method = method);
                },
                child: const Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: LatencyCalibrationMethod.automatic,
                      title: Text('自动测'),
                      subtitle: Text('用外放，或把一只耳机贴近手机底部的麦克风。听见短促的测试音时保持安静。'),
                    ),
                    RadioListTile(
                      contentPadding: EdgeInsets.zero,
                      value: LatencyCalibrationMethod.tapAlong,
                      title: Text('跟拍测'),
                      subtitle: Text(
                        '戴任意耳机，蓝牙也可以。听完三下倒数，跟着接下来的 12 下节拍唱“嗒”或拍手。'
                        '测的是你听到节拍再唱出来的总延迟，练习会用它对齐你的声音。',
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ],
        ),
        actions: [
          TextButton(onPressed: _saving || _closing ? null : _cancel, child: const Text('取消')),
          if (!busy) TextButton(onPressed: _saving ? null : _run, child: Text(_result == null ? '开始测量' : '再测一次')),
          if (reading != null) FilledButton(onPressed: _saving ? null : () => _use(reading), child: const Text('使用')),
        ],
      ),
    );
  }
}

String _failureMessage(LatencyCalibrationFailure failure) => switch (failure) {
  LatencyCalibrationFailure.noTestSound => '没听到测试音。请调到听得清的音量，或把耳机贴近手机底部的麦克风，再测一次。',
  LatencyCalibrationFailure.inconsistentTestSound => '几下测试音测出的延迟差得太远。请保持安静，拿稳手机和耳机，再测一次。',
  LatencyCalibrationFailure.unsteadyBeat => '没测到足够稳定的跟拍。请戴好耳机，听完倒数再跟着每一下唱“嗒”或拍手。',
  LatencyCalibrationFailure.routeChanged => '音频线路变了，测量已停止。请接好要用的设备，再测一次。',
  LatencyCalibrationFailure.interrupted => '声音被打断了，测量已停止。请再测一次。',
  LatencyCalibrationFailure.noMicPermission => '没有麦克风权限。请在系统设置中允许音迹使用麦克风，再测一次。',
  LatencyCalibrationFailure.audioUnavailable => '音频暂时不可用，请稍后再测一次。',
  LatencyCalibrationFailure.cancelled => '测量已取消。',
};
