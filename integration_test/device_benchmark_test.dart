// Separation speed and memory on this device (lib/src/benchmark): one
// complete import, then CPU against Core ML. Run it on an iPhone with a
// profile build (release-like speed), see docs/device-benchmark.md:
//
//   tools/device_benchmark.sh <device-id> [song-seconds]
//
// The driver writes the report to build/integration_response_data.json on
// the Mac. --dart-define=BENCH_QUICK=1 runs a short version (CI simulator).
// Test builds of the app run the same benchmark from 设置 → 性能测试.
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/benchmark/benchmark_report.dart';
import 'package:yintrace/src/benchmark/device_benchmark.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace/src/models/model_catalog.dart';

// --dart-define=BENCH_QUICK=1 (or true).
const _quickDefine = String.fromEnvironment('BENCH_QUICK');
const _quick = _quickDefine == '1' || _quickDefine == 'true';
const _songSeconds = int.fromEnvironment('BENCH_SONG_SECONDS', defaultValue: _quick ? 12 : 60);

void log(String line) {
  // ignore: avoid_print
  print('[测速] $line');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device benchmark: a complete import, and CPU against Core ML', (tester) async {
    final services = await AppServices.init();
    log('准备模型（第一次会下载 451 MB）');
    await services.models.install(requiredModels: const [...separationModels, hubertFaModel]);
    expect(services.models.error, isNull);
    final bench = DeviceBenchmark(
      mdxPath: services.models.pathFor(vocalModel)!,
      vrPath: services.models.pathFor(karaokeModel)!,
      options: const BenchmarkOptions(songSeconds: _songSeconds, quick: _quick),
      // The vocal model with Core ML, checked against the CPU on its first
      // chunk, as on a device the first time.
      acceleration: const ImportAcceleration(coreML: vocalCoreMLOptions, verify: true),
      hubertFaPath: services.models.pathFor(hubertFaModel)!,
      pitchModelPath: services.pitchModelPath,
      onLog: log,
    );
    try {
      await bench.run();
    } finally {
      binding.reportData = {...bench.report, 'markdown': benchmarkMarkdown(bench.report)};
      log('报告 JSON：${jsonEncode(bench.report)}');
    }
    final report = bench.report;
    expect(report['error'], isNull);
    expect(report['finished_at'], isNotNull);
    final imp = report['import'] as Map;
    expect(imp['error'], isNull);
    expect(imp['alignment'], 'HuBERTFA', reason: imp['alignment_error']?.toString());
    expect(imp['mdx_runtime'], 'Core ML');
    expect('${imp['coreml_check']}', startsWith('checked'));
    expect(imp['mdx_run_s'], greaterThan(0));
    expect(imp['vr_run_s'], greaterThan(0));
    final cpu4 = (report['models'] as List).cast<Map>().where((r) => r['provider'] == 'CPU 4 线程').toList();
    expect(cpu4.map((r) => r['model']), _quick ? [benchMdx, benchVr] : [benchMdx, benchVr, benchVr320]);
    expect(cpu4.where((r) => r['error'] != null), isEmpty);
  }, timeout: const Timeout(Duration(minutes: 90)));
}
