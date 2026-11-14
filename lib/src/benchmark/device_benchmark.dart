// Separation speed and memory on this device: one complete import through
// the app's own background job, then both models with the CPU and with
// several Core ML set-ups. It runs from the 性能测试 page of test builds
// (built with --dart-define=YINTRACE_BENCHMARK=true) and from
// integration_test/device_benchmark_test.dart (tools/device_benchmark.sh).
//
// Only the two UVR files the app downloads and a song synthesized here are
// used: nothing is read from the library and nothing leaves the device.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../app/licenses.dart';
import '../audio/wav.dart';
import '../import/import_job.dart';
import '../import/import_pipeline.dart';
import '../separation/mdx_separator.dart';
import '../separation/model_config.dart';
import '../separation/onnx_model.dart';
import '../separation/tensor_model.dart';
import '../separation/vr_separator.dart';

const _flag = String.fromEnvironment('YINTRACE_BENCHMARK');

/// Whether this build shows the 性能测试 page: test builds made with
/// `--dart-define=YINTRACE_BENCHMARK=true`.
const benchmarkEnabled = _flag == 'true' || _flag == '1';

/// Core ML set-ups worth comparing (ONNX Runtime's Core ML provider options).
const coreMLSetups = <String, Map<String, String>>{
  // ONNX Runtime spells "all" in capitals (its header comment says "All").
  'Core ML MLProgram 全部单元': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'ALL'},
  'Core ML MLProgram CPU+神经网络引擎': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'CPUAndNeuralEngine'},
  'Core ML MLProgram CPU+GPU': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'CPUAndGPU'},
  'Core ML NeuralNetwork 全部单元': {'ModelFormat': 'NeuralNetwork', 'MLComputeUnits': 'ALL'},
};

/// Names of the measured models in the report.
const benchMdx = 'MDX T=128';
const benchMdxStatic = 'MDX T=128（固定形状）';
const benchVr = 'VR 512';
const benchVr320 = 'VR 320';

/// Layout version of [DeviceBenchmark.report].
const benchmarkReportVersion = 2;

/// The synthesized song repeats after this many seconds (melody, chords,
/// beat and [benchLyrics] all do).
const synthLoopSeconds = 16.0;

class BenchmarkOptions {
  const BenchmarkOptions({this.songSeconds = 60, this.quick = false});

  /// Length of the synthesized song that goes through the complete import.
  final int songSeconds;

  /// The short version (CI simulator): CPU with 4 threads only, Core ML on
  /// the fixed-shape MDX model with one set-up, one run each.
  final bool quick;
}

/// "4 分钟", "1 分 30 秒", "12 秒".
String benchDurationText(num seconds) {
  final s = seconds.round();
  if (s < 60) return '$s 秒';
  final m = s ~/ 60, r = s % 60;
  return r == 0 ? '$m 分钟' : '$m 分 $r 秒';
}

class _Step {
  const _Step(this.label, this.run);

  /// Also the step's id in the report (unique within a plan).
  final String label;

  /// Returns whether the step completed (false: stopped half way).
  final Future<bool> Function() run;
}

class _Input {
  _Input(this.data, this.shape);
  final Float32List data;
  final List<int> shape;
}

class _Inputs {
  _Inputs(this.mdx, this.vr, this.vr320);
  final _Input mdx, vr, vr320;
}

/// One run of the benchmark. Listen to it for progress. [report] holds the
/// results so far as plain JSON values; a page saves it whenever
/// [revision] changes, so what was measured survives the system closing the
/// app, and [DeviceBenchmark.resume] continues from it.
class DeviceBenchmark extends ChangeNotifier {
  DeviceBenchmark({required this.mdxPath, required this.vrPath, this.options = const BenchmarkOptions(), this.onLog});

  /// Continues [previous], a report whose run ended early. Finished steps
  /// are kept. The step that was running when the app was closed is
  /// recorded in `crashed` and skipped (its set-up most likely needs more
  /// memory than iOS allows), unless the app had left the foreground then:
  /// iOS may close any app in the background, so that step runs again.
  factory DeviceBenchmark.resume(
    Map<String, Object?> previous, {
    required String mdxPath,
    required String vrPath,
    void Function(String line)? onLog,
  }) {
    final o = previous['options'] is Map ? previous['options'] as Map : const {};
    final bench = DeviceBenchmark(
      mdxPath: mdxPath,
      vrPath: vrPath,
      options: BenchmarkOptions(songSeconds: (o['song_seconds'] as num?)?.toInt() ?? 60, quick: o['quick'] == true),
      onLog: onLog,
    );
    bench.report.addAll((jsonDecode(jsonEncode(previous)) as Map).cast<String, Object?>());
    bench._continueReport();
    return bench;
  }

  final String mdxPath;
  final String vrPath;
  final BenchmarkOptions options;
  final void Function(String line)? onLog;

  /// The results so far (JSON values only).
  final Map<String, Object?> report = {};

  /// Progress messages, oldest first.
  final List<String> log = [];

  /// Changes whenever [report] does.
  int revision = 0;

  bool running = false;

  /// 1-based number of the running step, of [stepCount].
  int stepIndex = 0;
  int stepCount = 0;
  String? stepLabel;

  /// Progress of the import while that step runs.
  ImportProgress? importProgress;

  bool _started = false;
  bool _cancelled = false;
  ImportJob? _job;
  late Directory _tmp;
  _Inputs? _inputs;
  String? _staticMdx;
  int _caches = 0;

  /// The first CPU output of each model: what Core ML is compared with.
  final _cpuOutputs = <String, Float32List>{};

  /// Stops after the running model measurement (an import stops right away).
  Future<void> cancel() async {
    _cancelled = true;
    _say('正在停止…');
    await _job?.cancel();
  }

  /// Records that the app left the foreground during the running step; its
  /// numbers are then too slow.
  void noteBackground() {
    final step = report['running'];
    if (step is! String) return;
    final list = _list('backgrounded');
    if (list.contains(step)) return;
    list.add(step);
    _bump();
  }

  Future<Map<String, Object?>> run() async {
    if (_started) throw StateError('a DeviceBenchmark runs once');
    _started = true;
    running = true;
    if (report.isEmpty) _describeDevice();
    await _removeLeftovers();
    _tmp = await Directory.systemTemp.createTemp('yintrace_bench');
    try {
      final plan = _plan();
      final skip = {..._list('done_steps'), ..._list('crashed')};
      stepCount = plan.length;
      stepIndex = plan.where((s) => skip.contains(s.label)).length;
      for (final step in plan) {
        if (skip.contains(step.label)) continue;
        if (_cancelled) break;
        stepIndex++;
        stepLabel = step.label;
        report['running'] = step.label;
        _bump();
        _say('第 $stepIndex / $stepCount 项：${step.label}');
        var completed = true;
        try {
          completed = await step.run();
        } catch (e) {
          // One broken step (say, preparing its input) does not end the run.
          final message = '$e'.split('\n').first;
          final errors = report['step_errors'] is Map ? report['step_errors'] as Map : <String, Object?>{};
          report['step_errors'] = {...errors, step.label: message};
          _say('「${step.label}」出错：$message');
        }
        report['running'] = null;
        if (completed) _list('done_steps').add(step.label);
        _bump();
      }
      if (_cancelled) {
        report['cancelled'] = true;
        _say('已停止。已经测完的项目都在报告里。');
      } else {
        report['finished_at'] = DateTime.now().toIso8601String();
        _say('测试完成');
      }
    } catch (e) {
      report['running'] = null;
      report['error'] = '$e'.split('\n').first;
      _say('出错了：${report['error']}');
    } finally {
      running = false;
      stepLabel = null;
      importProgress = null;
      try {
        await _tmp.delete(recursive: true);
      } catch (_) {}
      _bump();
    }
    return report;
  }

  void _describeDevice() {
    final simulated = Platform.environment['SIMULATOR_MODEL_IDENTIFIER'];
    final model = simulated != null ? '$simulated（模拟器）' : NativeAudio.deviceModel;
    final cores = Platform.numberOfProcessors;
    final physical = NativeAudio.physicalMemory;
    final available = NativeAudio.availableMemory;
    report.addAll({
      'version': benchmarkReportVersion,
      'app_version': appVersion,
      'options': {'song_seconds': options.songSeconds, 'quick': options.quick},
      'device': {
        'model': model,
        'os': Platform.operatingSystemVersion,
        'cores': cores,
        'memory_gb': physical == null ? null : physical / (1 << 30),
        'available_memory_mb_at_start': available == null ? null : available / 1e6,
        'thermal_at_start': _thermal(),
      },
      'started_at': DateTime.now().toIso8601String(),
      'models': <Object?>[],
      'done_steps': <Object?>[],
    });
    _say('开始测试${options.quick ? '（快速模式）' : ''}：${model ?? '未知型号'}，'
        '${Platform.operatingSystemVersion}，$cores 核，可用内存 ${_mb(available)}');
  }

  void _continueReport() {
    report
      ..remove('cancelled')
      ..remove('error')
      ..remove('finished_at');
    final step = report.remove('running');
    if (step is String) {
      if (_list('backgrounded').contains(step)) {
        _say('上次测「$step」时 App 在后台被关闭，这一项重新测');
      } else {
        _list('crashed').add(step);
        _say('上次测「$step」时 App 被系统关闭（多半是内存不够），这一项跳过');
      }
    }
    report['resumed'] = ((report['resumed'] as num?) ?? 0).toInt() + 1;
    _say('继续上次没做完的测试');
  }

  /// What this run will measure, in order (steps already in a resumed
  /// report included).
  List<String> get plannedSteps => [for (final s in _plan()) s.label];

  List<_Step> _plan() {
    final quick = options.quick;
    final cores = Platform.numberOfProcessors;
    final threads = quick ? const [4] : [4, 2, if (cores != 4 && cores != 2) cores];
    final coreML = quick ? [coreMLSetups.entries.first] : coreMLSetups.entries.toList();
    _Step cpu(String name, int t) => _Step('$name · CPU $t 线程', () => _model(name, 'CPU $t 线程', threads: t));
    _Step ml(String name, MapEntry<String, Map<String, String>> e) =>
        _Step('$name · ${e.key}', () => _model(name, e.key, coreML: e.value));
    _Step cache(String name) => _Step('$name · Core ML 编译缓存', () => _cache(name));
    // The import first, then everything on the CPU: the numbers that matter
    // most are in before a Core ML set-up can make iOS close the app.
    // The quick version (simulator) tries Core ML on one model only: there
    // Core ML compiles on the host CPU, which takes minutes per model.
    return [
      _Step('完整导入 ${benchDurationText(options.songSeconds)}的合成歌曲', _import),
      for (final t in threads) cpu(benchMdx, t),
      for (final t in threads) cpu(benchVr, t),
      if (!quick)
        for (final t in threads) cpu(benchVr320, t),
      if (!quick)
        for (final e in coreML) ml(benchMdx, e),
      for (final e in coreML) ml(benchMdxStatic, e),
      if (!quick)
        for (final e in coreML) ml(benchVr, e),
      if (!quick) ...[cache(benchMdx), cache(benchMdxStatic), cache(benchVr)],
    ];
  }

  /// One complete import through the app's own background job.
  Future<bool> _import() async {
    final seconds = options.songSeconds;
    final song = '${_tmp.path}/bench-song.wav';
    await _writeSongInBackground(song, seconds);
    final r = <String, Object?>{'song_seconds': seconds};
    final memory = _MemorySampler()..begin();
    final watch = Stopwatch()..start();
    final stages = <String, double>{};
    final estimates = <List<double>>[]; // [elapsed, estimated remaining]
    var lastLog = -10.0;
    var completed = true;
    try {
      final job = await ImportJob.start(
        ImportRequest(
          audioPath: song,
          lyrics: benchLyrics(seconds.toDouble()),
          title: '测速',
          mdxModelPath: mdxPath,
          vrModelPath: vrPath,
          keepOriginal: false,
        ),
        '${_tmp.path}/songs',
      );
      _job = job;
      if (_cancelled) await job.cancel();
      await for (final e in job.events) {
        final t = watch.elapsedMilliseconds / 1000;
        switch (e) {
          case ImportProgressEvent(:final progress):
            importProgress = progress;
            stages.putIfAbsent(progress.stage.label, () => t);
            final left = progress.remaining;
            if (left != null) estimates.add([t, left.inMilliseconds / 1000]);
            if (t - lastLog >= 10) {
              lastLog = t;
              _say('导入 ${(progress.overall * 100).floor()}% ${progress.stage.label} '
                  '${progress.done ?? ''}${progress.total == null ? '' : '/${progress.total}'}'
                  '，已用 ${t.round()} 秒${left == null ? '' : '，预计还需 ${left.inSeconds} 秒'}');
            } else {
              notifyListeners();
            }
          case ImportDoneEvent(:final song):
            r['vr'] = song.modelInfo['vr'];
          case ImportFailedEvent(:final message, :final cancelled):
            if (cancelled) completed = false;
            r['error'] = cancelled ? '已停止' : message;
        }
      }
    } catch (e) {
      r['error'] = '$e';
    } finally {
      _job = null;
      importProgress = null;
    }
    final total = watch.elapsedMilliseconds / 1000;
    r['total_s'] = total;
    r['realtime_factor'] = total / seconds;
    r['peak_footprint_mb'] = memory.end();
    r['thermal'] = _thermal();
    // Seconds from the start of each stage to the start of the next.
    final names = stages.keys.toList();
    r['stages_s'] = {
      for (var i = 0; i < names.length; i++)
        names[i]: (i + 1 < names.length ? stages[names[i + 1]]! : total) - stages[names[i]]!,
    };
    // How good the remaining-time estimate was at a quarter, half and three
    // quarters of the way (positive: it promised less time than it took).
    r['estimate_error_s'] = {
      for (final q in [0.25, 0.5, 0.75])
        '${(q * 100).round()}%': () {
          final at = estimates.where((s) => s[0] >= q * total).firstOrNull;
          return at == null ? null : (total - at[0]) - at[1];
        }(),
    };
    report['import'] = r;
    _say('导入用时 ${benchDurationText(total)}（${(total / seconds).toStringAsFixed(2)} 倍歌曲时长），'
        '去和声窗口：${r['vr'] ?? '–'}，内存峰值 +${_mbValue(r['peak_footprint_mb'] as double?)}'
        '${r['error'] != null ? '，错误：${r['error']}' : ''}');
    return completed;
  }

  Future<bool> _model(String name, String provider, {int threads = 4, Map<String, String>? coreML}) async {
    final (path, input) = await _setup(name);
    final reference = coreML == null ? null : await _reference(name);
    _addRow(
      await _measure(
        name,
        provider,
        path,
        input,
        runs: options.quick ? 1 : 3,
        threads: threads,
        coreML: coreML,
        reference: reference,
      ),
    );
    return true;
  }

  /// Core ML compiles the model when a session is created; with a cache
  /// directory only the first import would pay for that.
  Future<bool> _cache(String name) async {
    final (path, input) = await _setup(name);
    final reference = await _reference(name);
    final setup = coreMLSetups.entries.first;
    final dir = await Directory('${_tmp.path}/coreml-cache-${_caches++}').create();
    final options = {...setup.value, 'ModelCacheDirectory': dir.path};
    for (final pass in ['建缓存', '用缓存再加载']) {
      _addRow(await _measure(name, '${setup.key}（$pass）', path, input, runs: 1, coreML: options, reference: reference));
    }
    return true;
  }

  Future<(String, _Input)> _setup(String name) async {
    final inputs = _inputs ??= await _captureInputs();
    return switch (name) {
      benchMdx => (mdxPath, inputs.mdx),
      benchMdxStatic => (await _staticMdxPath(), inputs.mdx),
      benchVr => (vrPath, inputs.vr),
      _ => (vrPath, inputs.vr320),
    };
  }

  /// Inputs shaped like a real song: the tensors the app's own separators
  /// build from 10 s of the synthesized one.
  Future<_Inputs> _captureInputs() {
    _say('准备模型输入');
    return _captureInBackground(math.min(options.songSeconds.toDouble(), synthLoopSeconds));
  }

  Future<String> _staticMdxPath() async {
    if (_staticMdx case final path?) return path;
    final recipe = jsonDecode(await rootBundle.loadString('assets/models/mdx_graph.json')) as Map<String, dynamic>;
    final offsets = (recipe['patchOffsets'] as List).cast<int>();
    final out = '${_tmp.path}/mdx-static-128.onnx';
    await _writeStaticMdxInBackground(mdxPath, out, offsets);
    return _staticMdx = out;
  }

  /// The CPU output Core ML is compared with: of the same model, or of the
  /// dynamic one for the fixed-shape MDX (same weights, same input).
  Future<Float32List?> _reference(String name) async {
    final key = name == benchMdxStatic ? benchMdx : name;
    if (_cpuOutputs[key] case final out?) return out;
    // The CPU steps ran before the app was closed: compute it again.
    _say('先在 CPU 上算一遍 $key 的参考输出');
    final (path, input) = await _setup(key);
    OnnxTensorModel? model;
    try {
      model = await OnnxTensorModel.load(path, threads: 4);
      return _cpuOutputs[key] = await model.run(input.data, input.shape);
    } catch (_) {
      return null;
    } finally {
      await model?.close();
    }
  }

  Future<Map<String, Object?>> _measure(
    String name,
    String provider,
    String path,
    _Input input, {
    required int runs,
    int threads = 4,
    Map<String, String>? coreML,
    Float32List? reference,
  }) async {
    final r = <String, Object?>{'model': name, 'provider': provider, 'shape': input.shape};
    final memory = _MemorySampler()..begin();
    OnnxTensorModel? model;
    Float32List? out;
    try {
      final w = Stopwatch()..start();
      model = await OnnxTensorModel.load(path, threads: threads, coreML: coreML);
      r['load_s'] = w.elapsedMilliseconds / 1000;
      w
        ..reset()
        ..start();
      await model.run(input.data, input.shape); // includes one-time setup
      r['first_run_s'] = w.elapsedMilliseconds / 1000;
      final times = <double>[];
      for (var i = 0; i < runs; i++) {
        w
          ..reset()
          ..start();
        out = await model.run(input.data, input.shape);
        times.add(w.elapsedMicroseconds / 1e6);
      }
      times.sort();
      r['run_s'] = times[times.length ~/ 2];
      final finite = r['finite'] = out!.every((v) => v.isFinite);
      if (finite && reference != null && reference.length == out.length) {
        var err = 0.0, sig = 0.0, maxErr = 0.0;
        for (var i = 0; i < out.length; i++) {
          final d = (out[i] - reference[i]).toDouble();
          err += d * d;
          sig += reference[i] * reference[i];
          maxErr = math.max(maxErr, d.abs());
        }
        // JSON has no infinity or NaN: identical outputs read as 300 dB.
        final snr = sig == 0 ? null : (err == 0 ? 300.0 : math.min(300.0, 10 * math.log(sig / err) / math.ln10));
        r['max_abs_diff'] = maxErr.isFinite ? maxErr : null;
        r['snr_vs_cpu_db'] = snr != null && snr.isFinite ? snr : null;
      }
      if (coreML == null) _cpuOutputs.putIfAbsent(name, () => out!);
    } catch (e) {
      r['error'] = '$e'.split('\n').first;
    } finally {
      await model?.close();
      r['peak_footprint_mb'] = memory.end();
      r['process_max_rss_mb'] = ProcessInfo.maxRss / 1e6;
      r['thermal'] = _thermal();
    }
    final line = r['error'] != null
        ? '失败：${r['error']}'
        : '加载 ${r['load_s']} 秒，首次 ${r['first_run_s']} 秒，每次 ${(r['run_s'] as double).toStringAsFixed(3)} 秒'
              '${r['snr_vs_cpu_db'] != null ? '，与 CPU 差值比 ${(r['snr_vs_cpu_db'] as double).toStringAsFixed(1)} dB' : ''}'
              '，内存峰值 +${_mbValue(r['peak_footprint_mb'] as double?)}';
    _say('$name · $provider：$line');
    return r;
  }

  void _addRow(Map<String, Object?> row) {
    _list('models').add(row);
    _bump();
  }

  List<Object?> _list(String key) {
    final value = report[key];
    if (value is List<Object?>) return value;
    final list = <Object?>[];
    report[key] = list;
    return list;
  }

  void _say(String line) {
    log.add(line);
    if (log.length > 400) log.removeRange(0, log.length - 400);
    onLog?.call(line);
    notifyListeners();
  }

  void _bump() {
    revision++;
    notifyListeners();
  }

  /// Folders of runs the system ended (they live in the app's own tmp).
  static Future<void> _removeLeftovers() async {
    try {
      await for (final e in Directory.systemTemp.list()) {
        if (e is Directory && e.path.split(Platform.pathSeparator).last.startsWith('yintrace_bench')) {
          await e.delete(recursive: true);
        }
      }
    } catch (_) {}
  }

  static String? _thermal() {
    try {
      return NativeAudio.thermalState?.name;
    } catch (_) {
      return null;
    }
  }
}

// The heavy Dart work runs off the UI isolate. Top-level, so each closure
// carries only its arguments to the other isolate.
Future<void> _writeSongInBackground(String path, int seconds) =>
    Isolate.run(() => writeSynthSong(path, seconds.toDouble()));

Future<_Inputs> _captureInBackground(double seconds) => Isolate.run(() => _capture(seconds));

Future<void> _writeStaticMdxInBackground(String source, String out, List<int> offsets) =>
    Isolate.run(() => writeStaticMdx(source, out, offsets));

String _mb(int? bytes) => bytes == null ? '未知' : '${(bytes / 1e6).round()} MB';

String _mbValue(double? mb) => mb == null ? '未知' : '${mb.round()} MB';

/// Smallest memory headroom iOS reports while a measurement runs.
class _MemorySampler {
  _MemorySampler() : start = NativeAudio.availableMemory;
  final int? start;
  int? _min;
  Timer? _timer;

  void begin() {
    _min = start;
    _timer = Timer.periodic(const Duration(milliseconds: 20), (_) {
      final now = NativeAudio.availableMemory;
      if (now != null && (_min == null || now < _min!)) _min = now;
    });
  }

  /// Peak growth of the app's memory footprint, in MB (null where iOS does
  /// not report it, e.g. on the simulator).
  double? end() {
    _timer?.cancel();
    final s = start, m = _min;
    return s == null || m == null ? null : (s - m) / 1e6;
  }
}

/// Records the [index]-th tensor a separator hands to its model.
class _CaptureModel implements TensorModel {
  _CaptureModel(this.index);
  final int index;
  int _calls = 0;
  _Input? input;

  @override
  Future<Float32List> run(Float32List x, List<int> shape) async {
    if (_calls++ == index) input = _Input(Float32List.fromList(x), List.of(shape));
    return Float32List(x.length);
  }

  @override
  Future<void> close() async {}
}

Future<_Inputs> _capture(double seconds) async {
  final song = synthSong(seconds);
  final clip = Float32List.sublistView(song, 0, math.min(song.length, 2 * 10 * 44100));
  Future<_Input> one(Future<Object?> Function(TensorModel m) separate, int index) async {
    final m = _CaptureModel(index);
    await separate(m);
    return m.input!;
  }

  return _Inputs(
    await one((m) => MdxSeparator(m, MdxConfig.vocFt).separate(clip), 1),
    await one((m) => VrSeparator(m, VrConfig.karaoke6Hp).separate(clip), 1),
    await one((m) => VrSeparator(m, VrConfig.karaoke6Hp.withWindowSize(320)).separate(clip), 2),
  );
}

/// The dynamic MDX model with its time axis fixed to 128 again (the same six
/// bytes the install recipe changed, now `dim_value: 128`). Core ML may run a
/// fixed shape better.
void writeStaticMdx(String dynamicPath, String out, List<int> patchOffsets) {
  final bytes = File(dynamicPath).readAsBytesSync();
  for (final offset in patchOffsets) {
    if (bytes[offset] != 0x12 || bytes[offset + 1] != 0x01 || bytes[offset + 2] != 0x54) {
      throw StateError('unexpected bytes at $offset');
    }
    bytes.setAll(offset, const [0x08, 0x80, 0x01]); // dim_value: 128
  }
  File(out).writeAsBytesSync(bytes, flush: true);
}

/// Writes [seconds] of [synthSong] to [path] as 16-bit stereo WAV at
/// 44.1 kHz. Longer songs repeat the first [synthLoopSeconds], so even a
/// long one needs little memory.
void writeSynthSong(String path, double seconds) {
  const sr = 44100;
  final frames = (seconds * sr).round();
  final loop = synthSong(math.min(seconds, synthLoopSeconds));
  final file = File(path).openSync(mode: FileMode.write);
  try {
    file.writeFromSync(wav16Header(2 * frames, 2, sr));
    final block = Int16List(2 * sr);
    for (var done = 0; done < frames; done += sr) {
      final n = math.min(sr, frames - done);
      for (var i = 0; i < 2 * n; i++) {
        final v = (loop[(2 * done + i) % loop.length] * 32767).round();
        block[i] = v > 32767 ? 32767 : (v < -32768 ? -32768 : v);
      }
      file.writeFromSync(block.buffer.asUint8List(0, 4 * n));
    }
  } finally {
    file.closeSync();
  }
}

/// Lyrics that follow [synthSong]: a line of eight 0.5 s syllables every
/// 4 s (original text written for this project).
String benchLyrics(double seconds) {
  const phrases = ['墨线轻轻画过谱页', '清声沿着音阶向前', '窗前的光照亮歌声', '慢慢收起余音'];
  final b = StringBuffer();
  for (var i = 0; i * 4 < seconds - 4; i++) {
    final t = i * 4;
    b.writeln('[${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toString().padLeft(2, '0')}.00]${phrases[i % 4]}');
  }
  return b.toString();
}

/// A deterministic stand-in for a song (the idea of
/// tools/reference/make_real_reference.py): a lead voice with 0.5 s
/// syllables in the centre, a harmony voice to the sides, pad chords, bass,
/// kick and hi-hat. Interleaved stereo at 44.1 kHz.
Float32List synthSong(double seconds) {
  const sr = 44100;
  final n = (seconds * sr).round();
  final left = Float64List(n), right = Float64List(n);
  void voice(List<int> notes, double gl, double gr, double vibrato) {
    var phase = 0.0;
    for (var i = 0; i < n; i++) {
      final t = i / sr;
      final midi = notes[(t / 0.5).floor() % notes.length];
      phase += 440 * math.pow(2, (midi - 69) / 12) * (1 + 0.01 * math.sin(2 * math.pi * 5.5 * t + vibrato)) / sr;
      var x = 0.6 * math.sin(2 * math.pi * 3 * phase) + 0.4 * math.sin(2 * math.pi * 7 * phase);
      for (var h = 1; h < 12; h++) {
        x += math.sin(2 * math.pi * h * phase) / h;
      }
      final env = (math.sin(math.pi * ((t / 0.5) % 1)) * 2.5).clamp(0.0, 1.0);
      left[i] += 0.11 * x * env * gl;
      right[i] += 0.11 * x * env * gr;
    }
  }

  voice(const [64, 66, 68, 69, 68, 66, 64, 61], 1, 1, 0);
  voice(const [68, 69, 71, 73, 71, 69, 68, 64], 0.405, 0.1125, 1.3);
  const chords = [
    [57, 61, 64],
    [52, 56, 59],
    [54, 57, 61],
    [50, 54, 57],
  ];
  for (var i = 0; i < n; i++) {
    final t = i / sr;
    final chord = chords[(t / 2).floor() % chords.length];
    final tt = t % 2;
    for (var k = 0; k < chord.length; k++) {
      final f = 440 * math.pow(2, (chord[k] - 69) / 12);
      final w = 0.05 * (2 * (2 * ((f * tt) % 1) - 1).abs() - 1);
      left[i] += (0.7 - 0.2 * k) * w;
      right[i] += (0.3 + 0.2 * k) * w;
    }
    final bass = 0.12 * math.sin(2 * math.pi * 440 * math.pow(2, (chord[0] - 24 - 69) / 12) * tt);
    left[i] += bass;
    right[i] += bass;
  }
  // Kick on every beat, noise hi-hat on every half beat.
  final rng = math.Random(7);
  double gauss() => math.sqrt(-2 * math.log(1 - rng.nextDouble())) * math.cos(2 * math.pi * rng.nextDouble());
  for (var k = 0; k < (seconds / 0.25).floor(); k++) {
    final a = (k * 0.25 * sr).floor();
    final m = math.min(n - a, (0.15 * sr).floor());
    for (var j = 0; j < m; j++) {
      final tt = j / sr;
      var v = 0.04 * math.exp(-tt / 0.012) * gauss();
      if (k.isEven) v += 0.3 * math.exp(-tt / 0.05) * math.sin(2 * math.pi * (50 + 90 * math.exp(-tt / 0.02)) * tt);
      left[a + j] += v;
      right[a + j] += v;
    }
  }
  // Peak 0.8 like the reference clip: the vocal model separates quiet input
  // much worse (at peak 0.5 it finds no voice in this song at all).
  var peak = 1e-9;
  for (var i = 0; i < n; i++) {
    peak = math.max(peak, math.max(left[i].abs(), right[i].abs()));
  }
  final out = Float32List(2 * n);
  for (var i = 0; i < n; i++) {
    out[2 * i] = left[i] * 0.8 / peak;
    out[2 * i + 1] = right[i] * 0.8 / peak;
  }
  return out;
}
