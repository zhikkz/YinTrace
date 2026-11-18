import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/benchmark/benchmark_report.dart';
import 'package:yintrace/src/benchmark/device_benchmark.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace/src/ui/benchmark_page.dart';
import 'package:yintrace/src/ui/theme.dart';

import 'support/benchmark_sample.dart';

void main() {
  test('durations read naturally', () {
    expect(benchDurationText(12), '12 秒');
    expect(benchDurationText(60), '1 分钟');
    expect(benchDurationText(240), '4 分钟');
    expect(benchDurationText(312.4), '5 分 12 秒');
  });

  test('the benchmark lyrics cover the synthesized song', () {
    final lyrics = parseLrc(benchLyrics(240));
    expect(lyrics.errors, isEmpty);
    expect(lyrics.lines.length, 59); // a line every 4 s, the last one ending by 240 s
    expect(lyrics.lines.first.text, '墨线轻轻画过谱页');
    expect(lyrics.lines[4].start, 16.0);
  });

  test('a long synthesized song repeats the 16-second loop', () {
    final dir = Directory.systemTemp.createTempSync('yt_bench_test');
    addTearDown(() => dir.deleteSync(recursive: true));
    final path = '${dir.path}/song.wav';
    writeSynthSong(path, 40);
    final wav = readWavFile(path);
    expect(wav.channels, 2);
    expect(wav.sampleRate, 44100);
    expect(wav.frames, 40 * 44100);
    final loop = synthSong(synthLoopSeconds);
    const period = 2 * 16 * 44100;
    for (final i in [0, 1, 12345, 2 * 44100 * 7 + 1]) {
      expect(wav.samples[i], closeTo(loop[i], 1 / 32767));
      expect(wav.samples[i + period], wav.samples[i]);
      expect(wav.samples[i + 2 * period], wav.samples[i]);
    }
    var peak = 0.0;
    for (final v in wav.samples) {
      if (v.abs() > peak) peak = v.abs();
    }
    expect(peak, closeTo(0.8, 0.01));
  });

  group('plan', () {
    test('the quick version measures a few set-ups', () {
      final bench = DeviceBenchmark(
        mdxPath: 'm',
        vrPath: 'v',
        options: const BenchmarkOptions(songSeconds: 12, quick: true),
      );
      expect(bench.plannedSteps, [
        '完整导入 12 秒的合成歌曲',
        '$benchMdx · CPU 4 线程',
        '$benchVr · CPU 4 线程',
        '$benchMdx · Core ML MLProgram CPU+GPU',
      ]);
      expect(coreMLSetups.values.first, vocalCoreMLOptions, reason: 'the app\'s own set-up comes first');
    });

    test('the full version: import, every CPU set-up, then Core ML', () {
      final steps = DeviceBenchmark(mdxPath: 'm', vrPath: 'v').plannedSteps;
      expect(steps.first, '完整导入 1 分钟的合成歌曲');
      expect(steps.toSet(), hasLength(steps.length), reason: 'labels are the step ids');
      final firstCoreML = steps.indexWhere((s) => s.contains('Core ML'));
      expect(steps.sublist(1, firstCoreML).every((s) => s.contains(' · CPU ')), isTrue);
      for (final setup in coreMLSetups.keys) {
        expect(steps, contains('$benchMdx · $setup'));
      }
      expect(steps.last, '$benchMdx · Core ML 编译缓存');
      // The karaoke model only on the CPU: every Core ML set-up made iOS
      // close the app on an iPhone.
      expect(steps.where((s) => s.startsWith('VR ')).every((s) => s.contains(' · CPU ')), isTrue);
    });

    test('resuming skips the set-up that made iOS close the app', () {
      final previous = sampleReport()
        ..remove('finished_at')
        ..['running'] = '$benchVr · ${coreMLSetups.keys.first}';
      final bench = DeviceBenchmark.resume(previous, mdxPath: 'm', vrPath: 'v');
      expect(bench.options.songSeconds, 240);
      expect(bench.report['crashed'], ['$benchVr · ${coreMLSetups.keys.first}']);
      expect(bench.report['running'], isNull);
      expect(bench.report['resumed'], 1);
      expect((bench.report['models'] as List).length, 6, reason: 'earlier results are kept');
      expect(previous['crashed'], isNull, reason: 'the saved report is not changed');
    });

    test('a step that was running in the background runs again', () {
      final step = '$benchVr · ${coreMLSetups.keys.first}';
      final previous = sampleReport()
        ..remove('finished_at')
        ..['running'] = step
        ..['backgrounded'] = [step];
      final bench = DeviceBenchmark.resume(previous, mdxPath: 'm', vrPath: 'v');
      expect(bench.report['crashed'], isNull);
      expect(bench.report['running'], isNull);
    });
  });

  group('report', () {
    test('conclusions: the import, and the fastest set-up close enough to the CPU', () {
      final c = benchmarkConclusions(sampleReport());
      expect(c, [
        '导入 4 分钟的歌用了 5 分 12 秒，是歌曲时长的 1.30 倍。',
        '$benchMdx：仍是「CPU 4 线程」最快（没有更快且结果足够接近的设置），每次 1.900 秒。',
        '$oldStatic：最快且结果可靠的是「Core ML MLProgram 全部单元」，每次 0.500 秒，是 CPU 4 线程的 3.80 倍速度。',
        '$benchVr：仍是「CPU 4 线程」最快（没有更快且结果足够接近的设置），每次 2.200 秒。',
      ]);
    });

    test('Markdown with the device, the import, notes and a table', () {
      final report = sampleReport()
        ..['crashed'] = ['$benchVr · Core ML MLProgram 全部单元']
        ..['backgrounded'] = ['$benchMdx · CPU 2 线程']
        ..['step_errors'] = {'$benchMdx · Core ML 编译缓存': 'StateError: no cache directory'};
      final md = benchmarkMarkdown(jsonDecode(jsonEncode(report)) as Map<String, Object?>);
      expect(md, startsWith('# 音迹真机测速报告\n'));
      expect(md, contains('- 设备：iPhone15,2，6 核，内存 5.6 GB'));
      expect(md, contains('- 开始时系统允许 App 再用的内存：2950 MB\n'));
      expect(md, contains('App 被系统关闭了（多半是内存不够），已跳过：$benchVr · Core ML MLProgram 全部单元'));
      expect(md, contains('App 离开过前台，数字可能偏慢：$benchMdx · CPU 2 线程'));
      expect(md, contains('- 这些项目出错了：$benchMdx · Core ML 编译缓存（StateError: no cache directory）'));
      expect(md, contains('手机发热，系统可能降了速：$benchVr · Core ML MLProgram CPU+GPU'));
      expect(md, isNot(contains('没有做完')));
      expect(md, contains('| 总耗时 | 312.4 秒 |'));
      expect(md, contains('| 阶段：分离人声 | 150.3 秒 |'));
      expect(md, contains('| “预计还需”在 75% 处的误差 | – |'));
      expect(md, contains('| $oldStatic | Core ML MLProgram 全部单元 | 25.0 秒 | 0.90 秒 | 0.500 秒 | 3.80 倍 | 61.2 dB | – |  |'));
      expect(md, contains(r'OrtException \| CoreML: unsupported op；发热'), reason: 'a | in an error must not split the cell');
      expect(md.indexOf('## 完整导入'), lessThan(md.indexOf('## 结论')));
      expect(md.indexOf('## 结论'), lessThan(md.indexOf('## 单个模型')));
    });

    test('an unfinished or failed run says so', () {
      final unfinished = sampleReport()..remove('finished_at');
      expect(benchmarkMarkdown(unfinished), contains('- 测试没有做完，下面只有已经测完的项目'));
      expect(benchmarkMarkdown(unfinished..['cancelled'] = true), contains('- 测试中途停止了'));
      expect(benchmarkMarkdown(unfinished..['error'] = '磁盘满了'), contains('- 测试出错停下了：磁盘满了'));
      final empty = <String, Object?>{'device': <String, Object?>{}};
      expect(benchmarkConclusions(empty), isEmpty);
      expect(benchmarkMarkdown(empty), contains('- 设备：未知型号，– 核'));
    });
  });

  group('page', () {
    late Directory dir;
    String? copied;

    setUp(() {
      dir = Directory.systemTemp.createTempSync('yt_bench_page');
      copied = null;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        (call) async {
          if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
          return null;
        },
      );
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
        SystemChannels.platform,
        null,
      );
      dir.deleteSync(recursive: true);
    });

    Future<void> open(WidgetTester tester, Map<String, Object?>? saved) async {
      final file = File('${dir.path}/last.json');
      if (saved != null) file.writeAsStringSync(jsonEncode(saved));
      await tester.binding.setSurfaceSize(const Size(400, 1400));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      // The page reads the saved report with real file I/O.
      await tester.runAsync(() async {
        await tester.pumpWidget(
          MaterialApp(theme: buildTheme(Brightness.light), home: BenchmarkPage(storeFile: file)),
        );
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    testWidgets('first visit: what the test does and how long it takes', (tester) async {
      await open(tester, null);
      expect(find.text('开始测试'), findsOneWidget);
      expect(find.textContaining('全程大约 5 到 10 分钟'), findsOneWidget);
      expect(find.text('复制报告'), findsNothing);
    });

    testWidgets('a finished report: conclusions and copying it', (tester) async {
      await open(tester, sampleReport());
      expect(find.text('上次的测试已完成'), findsOneWidget);
      expect(find.text('导入 4 分钟的歌用了 5 分 12 秒，是歌曲时长的 1.30 倍。'), findsOneWidget);
      expect(find.text('接着测没做完的项目'), findsNothing);
      expect(find.text('重新测试'), findsOneWidget);
      await tester.tap(find.text('复制报告'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(copied, startsWith('# 音迹真机测速报告'));
      expect(find.textContaining('报告已复制'), findsOneWidget);
      await tester.tap(find.text('查看完整报告'));
      await tester.pumpAndSettle();
      expect(find.byType(SelectableText), findsOneWidget);
    });

    testWidgets('an unfinished report can be continued', (tester) async {
      await open(tester, sampleReport()..remove('finished_at'));
      expect(find.text('上次的测试没有做完（App 可能被系统关闭了）'), findsOneWidget);
      expect(find.text('接着测没做完的项目'), findsOneWidget);
    });
  });
}
