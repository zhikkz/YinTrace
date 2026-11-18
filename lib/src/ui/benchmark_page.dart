import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import '../app/screen_awake.dart';
import '../app/services.dart';
import '../benchmark/benchmark_report.dart';
import '../benchmark/device_benchmark.dart';
import '../models/model_catalog.dart';
import 'model_setup.dart';
import 'theme.dart';

/// 性能测试 (test builds only): how fast this phone separates a song, and
/// whether Core ML would be faster than the CPU. The report is saved after
/// every step, so what was measured survives the system closing the app,
/// and stays on the phone until the tester copies it.
class BenchmarkPage extends StatefulWidget {
  const BenchmarkPage({super.key, this.storeFile});

  /// Where the last report is kept (default: in the app's support folder).
  final File? storeFile;

  @override
  State<BenchmarkPage> createState() => _BenchmarkPageState();
}

class _BenchmarkPageState extends State<BenchmarkPage> with WidgetsBindingObserver {
  DeviceBenchmark? _bench;
  Map<String, Object?>? _last;
  int _songSeconds = 240;
  File? _file;
  int _savedRevision = -1;
  Future<void> _saving = Future.value();
  bool _stopping = false;
  bool _starting = false;
  final _clock = Stopwatch();
  final _awake = ScreenAwake();
  Timer? _ticker;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _load();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _ticker?.cancel();
    _bench?.removeListener(_changed);
    if (_bench?.running ?? false) _bench?.cancel();
    _awake.release();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.hidden || state == AppLifecycleState.paused) _bench?.noteBackground();
  }

  Future<void> _load() async {
    try {
      final file =
          widget.storeFile ?? File('${(await getApplicationSupportDirectory()).path}/benchmark/last-report.json');
      _file = file;
      if (!await file.exists()) return;
      final data = jsonDecode(await file.readAsString());
      if (data is Map && mounted) setState(() => _last = data.cast<String, Object?>());
    } catch (_) {}
  }

  void _save(Map<String, Object?> report) {
    final file = _file;
    if (file == null) return;
    final String text;
    try {
      text = jsonEncode(report);
    } catch (_) {
      return;
    }
    _saving = _saving.then((_) async {
      try {
        await file.parent.create(recursive: true);
        await file.writeAsString(text, flush: true);
      } catch (_) {}
    });
  }

  void _changed() {
    final bench = _bench;
    if (bench == null) return;
    if (bench.revision != _savedRevision) {
      _savedRevision = bench.revision;
      _save(bench.report);
    }
    if (mounted) setState(() {});
  }

  Future<void> _start({bool resume = false}) async {
    if (_starting || (_bench?.running ?? false)) return;
    _starting = true;
    try {
      await _run(resume: resume);
    } finally {
      _starting = false;
    }
  }

  Future<void> _run({required bool resume}) async {
    final services = AppScope.of(context);
    if (!await ensureModels(context)) return;
    if (!mounted) return;
    final mdx = services.models.pathFor(vocalModel)!;
    final vr = services.models.pathFor(karaokeModel)!;
    // The complete import runs the way the app's own imports do.
    final accel = await services.acceleration.beforeImport(mdx);
    if (!mounted) return;
    final last = _last;
    final bench = resume && last != null
        ? DeviceBenchmark.resume(
            last,
            mdxPath: mdx,
            vrPath: vr,
            acceleration: accel,
            pitchModelPath: services.activePitchModel,
            onImported: services.acceleration.afterImport,
          )
        : DeviceBenchmark(
            mdxPath: mdx,
            vrPath: vr,
            options: BenchmarkOptions(songSeconds: _songSeconds),
            acceleration: accel,
            pitchModelPath: services.activePitchModel,
            onImported: services.acceleration.afterImport,
          );
    _bench?.removeListener(_changed);
    bench.addListener(_changed);
    setState(() {
      _bench = bench;
      _stopping = false;
    });
    _awake.hold();
    _clock
      ..reset()
      ..start();
    _ticker?.cancel();
    _ticker = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
    try {
      await bench.run();
    } finally {
      _clock.stop();
      _ticker?.cancel();
      _ticker = null;
      _awake.release();
      _save(bench.report);
      if (mounted) setState(() => _last = Map.of(bench.report));
    }
  }

  Future<void> _stop() async {
    setState(() => _stopping = true);
    await _bench?.cancel();
  }

  Future<void> _copy(Map<String, Object?> report) async {
    await Clipboard.setData(ClipboardData(text: benchmarkMarkdown(report)));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('报告已复制，粘贴到聊天里发给开发者就行')));
  }

  @override
  Widget build(BuildContext context) {
    final bench = _bench;
    final running = bench?.running ?? false;
    return PopScope(
      canPop: !running,
      child: Scaffold(
        appBar: AppBar(title: const Text('性能测试')),
        body: running ? _buildRunning(context, bench!) : _buildIdle(context),
      ),
    );
  }

  Widget _buildIdle(BuildContext context) {
    final p = context.yt;
    final last = _last;
    Widget bullet(String text) => Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.only(top: 8, right: 10),
            child: Icon(Icons.circle, size: 5, color: p.inkSoft),
          ),
          Expanded(child: Text(text, style: context.type.bodyMedium)),
        ],
      ),
    );
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      children: [
        if (last != null) ...[_LastReport(report: last, onCopy: () => _copy(last), onResume: () => _start(resume: true)), const SizedBox(height: 28)],
        Text('测一测这台手机分离人声有多快，以及换用 Core ML（神经网络引擎、GPU）能不能更快。', style: context.type.bodyLarge),
        const SizedBox(height: 10),
        Text(
          'App 先自己合成一首歌，测试包含去和声的完整导入流程（分离人声、去和声、测音高），'
          '再用 CPU 和几种 Core ML 设置分别运行两个模型。平时导入默认不去和声，耗时可能比这里测得的更短。'
          '不读取你的曲库，不上传任何东西，测试用的文件测完就删掉。',
          style: context.type.bodyMedium,
        ),
        const SizedBox(height: 24),
        Text('测试前', style: context.type.titleMedium),
        const SizedBox(height: 10),
        bullet('全程大约 5 到 10 分钟。请接上电源，手机发热时系统会降速。'),
        bullet('让 YinTrace 一直在前台，不要锁屏或切到别的 App（屏幕会保持常亮）。'),
        bullet('这项测试需要两个分离模型（共 194 MB），缺少时会先下载，最好连着 Wi‑Fi。'),
        bullet('中途被打断也没关系：已经测完的项目会保留，回来可以接着测。'),
        const SizedBox(height: 22),
        Text('合成歌曲的长度', style: context.type.titleMedium),
        const SizedBox(height: 10),
        SegmentedButton<int>(
          segments: const [
            ButtonSegment(value: 60, label: Text('1 分钟')),
            ButtonSegment(value: 240, label: Text('4 分钟')),
          ],
          selected: {_songSeconds},
          showSelectedIcon: false,
          onSelectionChanged: (s) => setState(() => _songSeconds = s.first),
        ),
        const SizedBox(height: 6),
        Text('4 分钟和一首普通的歌差不多长，能看出包含去和声的完整导入要等多久；1 分钟能少等几分钟。', style: context.type.bodySmall),
        const SizedBox(height: 26),
        FilledButton(
          onPressed: () => _start(),
          child: Text(last == null ? '开始测试' : '重新测试'),
        ),
      ],
    );
  }

  static String _clockText(Duration d) {
    final s = d.inSeconds;
    return '${s ~/ 60}:${(s % 60).toString().padLeft(2, '0')}';
  }

  Widget _buildRunning(BuildContext context, DeviceBenchmark bench) {
    final p = context.yt;
    final imp = bench.importProgress;
    final total = bench.stepCount == 0 ? 1 : bench.stepCount;
    final fraction = ((bench.stepIndex - 1).clamp(0, total) + (imp?.overall ?? 0)) / total;
    final recent = bench.log.length > 6 ? bench.log.sublist(bench.log.length - 6) : bench.log;
    return Padding(
      padding: const EdgeInsets.fromLTRB(24, 8, 24, 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            bench.stepCount == 0 ? '准备中' : '第 ${bench.stepIndex} / ${bench.stepCount} 项',
            style: context.type.headlineMedium?.copyWith(fontFeatures: tabular),
          ),
          const SizedBox(height: 10),
          LinearProgressIndicator(
            value: bench.stepCount == 0 ? null : fraction.clamp(0.0, 1.0),
            minHeight: 4,
            borderRadius: BorderRadius.circular(2),
          ),
          const SizedBox(height: 12),
          Text(bench.stepLabel ?? '', style: context.type.titleMedium),
          if (imp != null) ...[
            const SizedBox(height: 4),
            Text(
              '导入 ${(imp.overall * 100).floor()}% · ${imp.stage.label}'
              '${imp.total != null ? ' ${imp.done ?? 0} / ${imp.total} 段' : ''}',
              style: context.type.bodyMedium?.copyWith(fontFeatures: tabular),
            ),
          ],
          const SizedBox(height: 4),
          Text(
            '已用 ${_clockText(_clock.elapsed)}',
            style: context.type.bodyMedium?.copyWith(color: p.inkSoft, fontFeatures: tabular),
          ),
          const SizedBox(height: 22),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(14),
            decoration: BoxDecoration(
              color: p.surface,
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: p.hairline),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                for (final line in recent)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 2),
                    child: Text(line, style: context.type.bodySmall?.copyWith(fontFeatures: tabular)),
                  ),
              ],
            ),
          ),
          const Spacer(),
          Text('请让 YinTrace 保持在前台，屏幕会保持常亮。测试会让手机发热，最好接上电源。', style: context.type.bodySmall),
          const SizedBox(height: 16),
          OutlinedButton(
            onPressed: _stopping ? null : _stop,
            style: OutlinedButton.styleFrom(alignment: Alignment.center),
            child: Text(_stopping ? '正在停止…（等这一项测完）' : '停止'),
          ),
        ],
      ),
    );
  }
}

/// The last report: its state, the conclusions, and how to send it.
class _LastReport extends StatelessWidget {
  const _LastReport({required this.report, required this.onCopy, required this.onResume});
  final Map<String, Object?> report;
  final VoidCallback onCopy;
  final VoidCallback onResume;

  @override
  Widget build(BuildContext context) {
    final p = context.yt;
    final finished = report['finished_at'] != null;
    final failed = report['error'] != null;
    final (Color color, String status) = finished
        ? (p.malachite, '上次的测试已完成')
        : failed
        ? (p.cinnabar, '上次的测试出错停下了')
        : report['cancelled'] == true
        ? (p.gamboge, '上次的测试中途停止了')
        : (p.gamboge, '上次的测试没有做完（App 可能被系统关闭了）');
    final conclusions = benchmarkConclusions(report);
    return Container(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
      decoration: BoxDecoration(
        color: p.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: p.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Container(width: 9, height: 9, decoration: BoxDecoration(shape: BoxShape.circle, color: color)),
              const SizedBox(width: 10),
              Expanded(child: Text(status, style: context.type.titleMedium)),
            ],
          ),
          const SizedBox(height: 12),
          if (conclusions.isEmpty) Text('还没有测完的项目。', style: context.type.bodyMedium),
          for (final c in conclusions)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(c, style: context.type.bodyMedium?.copyWith(fontFeatures: tabular)),
            ),
          const SizedBox(height: 6),
          FilledButton.tonal(onPressed: onCopy, child: const Text('复制报告')),
          const SizedBox(height: 4),
          Text('复制后粘贴到聊天里发给开发者。报告里只有测速结果、手机型号和系统版本。', style: context.type.bodySmall),
          if (!finished) ...[
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: onResume,
              style: OutlinedButton.styleFrom(alignment: Alignment.center),
              child: const Text('接着测没做完的项目'),
            ),
          ],
          TextButton(
            onPressed: () => Navigator.of(context).push(
              MaterialPageRoute<void>(builder: (_) => _ReportPage(markdown: benchmarkMarkdown(report), onCopy: onCopy)),
            ),
            child: const Text('查看完整报告'),
          ),
        ],
      ),
    );
  }
}

class _ReportPage extends StatelessWidget {
  const _ReportPage({required this.markdown, required this.onCopy});
  final String markdown;
  final VoidCallback onCopy;

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(
      title: const Text('完整报告'),
      actions: [IconButton(tooltip: '复制报告', icon: const Icon(Icons.copy_rounded), onPressed: onCopy)],
    ),
    body: SingleChildScrollView(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 32),
      child: SelectableText(markdown, style: context.type.bodySmall?.copyWith(fontFeatures: tabular, height: 1.5)),
    ),
  );
}
