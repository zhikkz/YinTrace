// The benchmark report: a few conclusions to read on the phone, and the
// whole thing as Markdown to paste into a chat or an issue. Input is
// DeviceBenchmark.report (also after a JSON round trip).
import 'device_benchmark.dart';

/// Core ML may change the numbers a little (it can compute in 16-bit
/// floats). Above this difference-to-CPU ratio the separation stays
/// practically the same.
const safeSnrDb = 40.0;

/// The conclusions: how long the import took, and the fastest reliable
/// set-up of each model.
List<String> benchmarkConclusions(Map<String, Object?> data) {
  final out = <String>[];
  final imp = _map(data['import']);
  final total = imp['total_s'], song = imp['song_seconds'], factor = imp['realtime_factor'];
  if (imp['error'] != null) {
    out.add('完整导入没有成功：${imp['error']}');
  } else if (total is num && song is num && factor is num) {
    final runtime = imp['mdx_runtime'];
    out.add('导入 ${benchDurationText(song)}的歌用了 ${benchDurationText(total)}，'
        '是歌曲时长的 ${factor.toStringAsFixed(2)} 倍'
        '${runtime == 'Core ML' ? '（人声分离用 GPU）' : runtime == 'CPU' ? '（人声分离用 CPU）' : ''}。');
  }
  final models = _rows(data);
  for (final name in {for (final m in models) m['model'] as String}) {
    final ok = models.where((m) => m['model'] == name && m['run_s'] is num && m['error'] == null).toList();
    final candidates = ok
        .where(
          (m) =>
              !_provider(m).contains('缓存') &&
              (_provider(m).startsWith('CPU') || ((m['snr_vs_cpu_db'] as num?) ?? 0) >= safeSnrDb),
        )
        .toList()
      ..sort((a, b) => (a['run_s'] as num).compareTo(b['run_s'] as num));
    if (ok.isEmpty) {
      out.add('$name：测过的设置都出错了。');
      continue;
    }
    if (candidates.isEmpty) {
      out.add('$name：能运行的 Core ML 设置，结果都和 CPU 差得太多（差值比低于 ${safeSnrDb.round()} dB）。');
      continue;
    }
    final best = candidates.first;
    final time = (best['run_s'] as num).toDouble();
    final cpu4 = _cpu4(models, name);
    if (best['provider'] == 'CPU 4 线程') {
      out.add('$name：仍是「CPU 4 线程」最快（没有更快且结果足够接近的设置），每次 ${time.toStringAsFixed(3)} 秒。');
    } else {
      out.add('$name：最快且结果可靠的是「${best['provider']}」，每次 ${time.toStringAsFixed(3)} 秒'
          '${cpu4 != null ? '，是 CPU 4 线程的 ${(cpu4 / time).toStringAsFixed(2)} 倍速度' : ''}。');
    }
  }
  return out;
}

/// The whole report as Markdown (Chinese).
String benchmarkMarkdown(Map<String, Object?> data) {
  final dev = _map(data['device']);
  final options = _map(data['options']);
  final memory = dev['memory_gb'];
  final available = dev['available_memory_mb_at_start'];
  final lines = <String>[
    '# YinTrace 真机测速报告',
    '',
    '- 设备：${dev['model'] ?? '未知型号'}，${dev['cores'] ?? '–'} 核'
        '${memory is num ? '，内存 ${memory.toStringAsFixed(1)} GB' : ''}',
    '- 系统：${dev['os'] ?? '–'}',
    '- 开始时系统允许 App 再用的内存：${_num(available, 0, ' MB')}${available == null ? '（未知，模拟器不报告）' : ''}',
    if (data['app_version'] != null) '- App 版本：${data['app_version']}',
    if (data['started_at'] is String) '- 开始时间：${_time(data['started_at'] as String)}',
    if (options['quick'] == true) '- 快速模式：只测了部分设置，每种只跑一次',
    if (data['resumed'] is num) '- 中途被打断过 ${data['resumed']} 次，之后接着测完了剩下的项目',
  ];
  final crashed = _strings(data['crashed']);
  if (crashed.isNotEmpty) {
    lines.add('- 这些项目测到一半 App 被系统关闭了（多半是内存不够），已跳过：${crashed.join('、')}');
  }
  final stepErrors = _map(data['step_errors']);
  if (stepErrors.isNotEmpty) {
    lines.add('- 这些项目出错了：${[for (final e in stepErrors.entries) '${e.key}（${e.value}）'].join('、')}');
  }
  final background = _strings(data['backgrounded']);
  if (background.isNotEmpty) {
    lines.add('- 测这些项目时 App 离开过前台，数字可能偏慢：${background.join('、')}');
  }
  if (data['finished_at'] == null) {
    lines.add(switch (data) {
      {'error': final String e} => '- 测试出错停下了：$e',
      {'cancelled': true} => '- 测试中途停止了，下面只有已经测完的项目',
      _ => '- 测试没有做完，下面只有已经测完的项目',
    });
  }
  final models = _rows(data);
  final imp = _map(data['import']);
  final hot = [
    if (_hot(imp['thermal'])) '完整导入',
    for (final m in models)
      if (_hot(m['thermal'])) '${m['model']} · ${m['provider']}',
  ];
  if (hot.isNotEmpty) lines.add('- 测这些项目时手机发热，系统可能降了速：${hot.join('、')}');
  lines.add('');

  if (imp.isNotEmpty) {
    final stages = _map(imp['stages_s']);
    final estimates = _map(imp['estimate_error_s']);
    lines
      ..addAll(['## 完整导入（App 实际的导入流程，CPU）', ''])
      ..addAll(
        _table(
          ['项目', '结果'],
          [
            ['合成歌曲时长', imp['song_seconds'] is num ? benchDurationText(imp['song_seconds'] as num) : '–'],
            ['总耗时', _num(imp['total_s'], 1, ' 秒')],
            ['耗时 / 歌曲时长', _num(imp['realtime_factor'], 2, ' 倍')],
            if (imp['mdx_runtime'] != null) ['人声分离用', _runtime(imp)],
            ['去和声窗口', '${imp['vr'] ?? '–'}'],
            if (imp['mdx_run_s'] != null) ['人声分离每次（导入中，含前后处理）', _num(imp['mdx_run_s'], 3, ' 秒')],
            if (imp['vr_run_s'] != null) ['去和声每次（导入中，含前后处理）', _num(imp['vr_run_s'], 3, ' 秒')],
            ['内存峰值增量', _num(imp['peak_footprint_mb'], 0, ' MB')],
            for (final e in stages.entries) ['阶段：${e.key}', _num(e.value, 1, ' 秒')],
            for (final e in estimates.entries) ['“预计还需”在 ${e.key} 处的误差', _num(e.value, 0, ' 秒')],
            if (imp['error'] != null) ['错误', '${imp['error']}'],
          ],
        ),
      )
      ..addAll(['', '误差为正：预计的时间比实际短。', '']);
  }

  final conclusions = benchmarkConclusions(data);
  if (conclusions.isNotEmpty) {
    lines
      ..addAll(['## 结论', ''])
      ..addAll(conclusions.map((c) => '- $c'))
      ..add('');
  }

  if (models.isNotEmpty) {
    lines
      ..addAll(['## 单个模型', ''])
      ..addAll(
        _table(
          ['模型', '计算方式', '加载', '第一次推理', '每次推理', '相对 CPU 4 线程', '与 CPU 差值比', '内存峰值增量', '备注'],
          [
            for (final m in models)
              [
                '${m['model']}',
                _provider(m),
                _num(m['load_s'], 1, ' 秒'),
                _num(m['first_run_s'], 2, ' 秒'),
                _num(m['run_s'], 3, ' 秒'),
                () {
                  final cpu4 = _cpu4(models, m['model'] as String), run = m['run_s'];
                  return cpu4 != null && run is num && run > 0 ? '${(cpu4 / run).toStringAsFixed(2)} 倍' : '–';
                }(),
                _num(m['snr_vs_cpu_db'], 1, ' dB'),
                _num(m['peak_footprint_mb'], 0, ' MB'),
                [
                  if (m['error'] != null) '${m['error']}',
                  if (m['finite'] == false) '输出里有无效数值',
                  if (_hot(m['thermal'])) '发热',
                ].join('；'),
              ],
          ],
        ),
      )
      ..addAll([
        '',
        '“加载”包括 Core ML 编译模型的时间（每次导入都要加载一次，用缓存后只有第一次慢）。'
            '“与 CPU 差值比”越高越接近 CPU 的结果，${safeSnrDb.round()} dB 以上分离结果实际上相同。'
            '内存峰值增量是 iOS 报告的 App 占用增加量。',
        '',
      ]);
  }
  return lines.join('\n');
}

Map<String, Object?> _map(Object? v) => v is Map ? v.cast<String, Object?>() : const {};

/// How the import ran the vocal model, and the outcome of the Core ML check.
String _runtime(Map<String, Object?> imp) {
  final check = '${imp['coreml_check'] ?? ''}';
  final note = switch (check) {
    '' => '',
    _ when check.startsWith('checked') => '，和 CPU 对比一致（${check.replaceFirst('checked ', '')}）',
    _ when check.startsWith('mismatch') => '；GPU 的结果和 CPU 不一致（${check.replaceFirst('mismatch ', '')}），改用了 CPU',
    _ when check.startsWith('invalid') => '；GPU 算出了无效的数值，改用了 CPU',
    _ => '；GPU 出错，改用了 CPU：${check.replaceFirst('error: ', '')}',
  };
  return '${imp['mdx_runtime'] == 'Core ML' ? 'GPU（Core ML）' : 'CPU'}$note';
}

List<Map<String, Object?>> _rows(Map<String, Object?> data) => [
  for (final m in (data['models'] is List ? data['models'] as List : const []))
    if (m is Map) m.cast<String, Object?>(),
];

List<String> _strings(Object? v) => v is List ? [for (final s in v) '$s'] : const [];

String _provider(Map<String, Object?> m) => '${m['provider'] ?? ''}';

/// The model's run time with the CPU and 4 threads (the app's setting); the
/// fixed-shape MDX model is compared with the dynamic one.
double? _cpu4(List<Map<String, Object?>> models, String name) {
  double? find(String n) {
    for (final m in models) {
      if (m['model'] == n && m['provider'] == 'CPU 4 线程' && m['run_s'] is num) return (m['run_s'] as num).toDouble();
    }
    return null;
  }

  return find(name) ?? (name.startsWith('MDX') ? find(benchMdx) : null);
}

bool _hot(Object? thermal) => thermal == 'serious' || thermal == 'critical';

String _num(Object? v, int digits, [String suffix = '']) => v is num ? '${v.toStringAsFixed(digits)}$suffix' : '–';

String _time(String iso) {
  final t = DateTime.tryParse(iso);
  if (t == null) return iso;
  String two(int n) => n.toString().padLeft(2, '0');
  return '${t.year}-${two(t.month)}-${two(t.day)} ${two(t.hour)}:${two(t.minute)}';
}

List<String> _table(List<String> head, List<List<String>> rows) {
  String cell(String s) => s.replaceAll('|', r'\|').replaceAll('\n', ' ');
  return [
    '| ${head.join(' | ')} |',
    '|${head.map((_) => '---').join('|')}|',
    for (final row in rows) '| ${row.map(cell).join(' | ')} |',
  ];
}
