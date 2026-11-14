// Separation speed and memory on this device: CPU against Core ML, and one
// complete import. Run it on an iPhone with a profile build (release-like
// speed), see docs/device-benchmark.md:
//
//   tools/device_benchmark.sh <device-id> [song-seconds]
//
// The driver writes the report to build/integration_response_data.json on
// the Mac. --dart-define=BENCH_QUICK=1 runs a short version (CI simulator).
// Only the two official UVR files (downloaded by the app) and a synthesized
// test song are used; nothing is uploaded anywhere.
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_job.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/separation/mdx_separator.dart';
import 'package:yintrace/src/separation/model_config.dart';
import 'package:yintrace/src/separation/onnx_model.dart';
import 'package:yintrace/src/separation/tensor_model.dart';
import 'package:yintrace/src/separation/vr_separator.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

const _quick = bool.fromEnvironment('BENCH_QUICK');
const _songSeconds = int.fromEnvironment('BENCH_SONG_SECONDS', defaultValue: _quick ? 12 : 60);

/// Core ML set-ups worth comparing (ONNX Runtime's Core ML provider options).
const _coreML = {
  'Core ML MLProgram 全部单元': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'All'},
  'Core ML MLProgram CPU+神经网络引擎': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'CPUAndNeuralEngine'},
  'Core ML MLProgram CPU+GPU': {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'CPUAndGPU'},
  'Core ML NeuralNetwork 全部单元': {'ModelFormat': 'NeuralNetwork', 'MLComputeUnits': 'All'},
};

void log(String line) {
  // ignore: avoid_print
  print('[测速] $line');
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('device benchmark: CPU against Core ML, and a complete import', (tester) async {
    final report = <String, Object?>{};
    final tmp = Directory.systemTemp.createTempSync('yintrace_bench');
    try {
      final services = await AppServices.init();
      final cores = Platform.numberOfProcessors;
      final available = NativeAudio.availableMemory;
      report['device'] = {
        'os': Platform.operatingSystemVersion,
        'cores': cores,
        'available_memory_mb_at_start': available == null ? null : available / 1e6,
        'quick': _quick,
      };
      log('${Platform.operatingSystemVersion}，$cores 核，可用内存 ${_mb(available)}');

      log('准备模型（第一次会下载 194 MB）');
      await services.models.install();
      expect(services.models.error, isNull);
      final mdxPath = services.models.pathFor(vocalModel)!;
      final vrPath = services.models.pathFor(karaokeModel)!;
      final staticMdx = await _staticMdx(mdxPath, '${tmp.path}/mdx-static-128.onnx');

      // Inputs shaped like a real song: the tensors the app's own code builds
      // from a synthesized one.
      final clip = synthSong(10);
      final mdxIn = await _capture((m) => MdxSeparator(m, MdxConfig.vocFt).separate(clip), 1);
      final vrIn = await _capture((m) => VrSeparator(m, VrConfig.karaoke6Hp).separate(clip), 1);
      final vr320In = await _capture(
        (m) => VrSeparator(m, VrConfig.karaoke6Hp.withWindowSize(320)).separate(clip),
        2,
      );

      final runs = _quick ? 1 : 3;
      final cpuThreads = _quick ? [4] : [4, 2, if (cores != 4 && cores != 2) cores];
      final coreML = _quick ? {_coreML.keys.first: _coreML.values.first} : _coreML;
      final results = <Map<String, Object?>>[];
      // Core ML results are compared with the first CPU run of the same
      // model ([referenceFrom]: of another file with the same weights).
      Future<void> model(
        String name,
        String path,
        _Input input, {
        bool cpu = true,
        bool ml = true,
        String? referenceFrom,
      }) async {
        if (cpu) {
          for (final threads in cpuThreads) {
            results.add((await _bench(name, 'CPU $threads 线程', path, input, runs: runs, threads: threads)).summary);
          }
        }
        final reference = _lastOutputs[referenceFrom ?? name];
        if (!ml) return;
        for (final entry in coreML.entries) {
          final r = await _bench(name, entry.key, path, input, runs: runs, coreML: entry.value, reference: reference);
          results.add(r.summary);
        }
        if (!_quick) {
          // Core ML compiles the model when a session is created; with a cache
          // directory only the first import would pay for that.
          final cache = Directory('${tmp.path}/coreml-cache-${name.hashCode}')..createSync();
          final options = {..._coreML.values.first, 'ModelCacheDirectory': cache.path};
          await _bench(name, '${_coreML.keys.first}（建缓存）', path, input, runs: 1, coreML: options);
          final cached = await _bench(name, '${_coreML.keys.first}（用缓存再加载）', path, input, runs: 1, coreML: options);
          results.add(cached.summary);
        }
      }

      await model('MDX T=128', mdxPath, mdxIn);
      await model('MDX T=128（固定形状）', staticMdx, mdxIn, cpu: false, referenceFrom: 'MDX T=128');
      await model('VR 512', vrPath, vrIn);
      await model('VR 320', vrPath, vr320In, ml: false);
      report['models'] = results;
      expect(results.where((r) => r['provider'] == 'CPU 4 线程' && r['error'] != null), isEmpty);

      log('完整导入：$_songSeconds 秒的合成歌曲（App 实际的导入流程，CPU）');
      report['import'] = await _import(tmp, mdxPath, vrPath);
      expect((report['import'] as Map)['error'], isNull);
    } finally {
      binding.reportData = report;
      // ignore: avoid_print
      print('[测速] 报告 JSON：${jsonEncode(report)}');
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 90)));
}

String _mb(int? bytes) => bytes == null ? '未知' : '${(bytes / 1e6).round()} MB';

/// Latest output of a model's first CPU configuration (reference for the
/// fixed-shape variant).
final _lastOutputs = <String, Float32List>{};

class _Input {
  _Input(this.data, this.shape);
  final Float32List data;
  final List<int> shape;
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

Future<_Input> _capture(Future<Object?> Function(TensorModel m) separate, int index) async {
  final m = _CaptureModel(index);
  await separate(m);
  return m.input!;
}

/// The dynamic MDX model with its time axis fixed to 128 again (the same six
/// bytes the install recipe changed, now `dim_value: 128`). Core ML may run a
/// fixed shape better.
Future<String> _staticMdx(String dynamicPath, String out) async {
  final recipe = jsonDecode(await rootBundle.loadString('assets/models/mdx_graph.json')) as Map<String, dynamic>;
  final bytes = File(dynamicPath).readAsBytesSync();
  for (final offset in (recipe['patchOffsets'] as List).cast<int>()) {
    if (bytes[offset] != 0x12 || bytes[offset + 1] != 0x01 || bytes[offset + 2] != 0x54) {
      throw StateError('unexpected bytes at $offset');
    }
    bytes.setAll(offset, const [0x08, 0x80, 0x01]); // dim_value: 128
  }
  File(out).writeAsBytesSync(bytes, flush: true);
  return out;
}

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

class _Result {
  _Result(this.summary);
  final Map<String, Object?> summary;
}

Future<_Result> _bench(
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
    r['finite'] = out!.every((v) => v.isFinite);
    if (reference != null && reference.length == out.length) {
      var err = 0.0, sig = 0.0, maxErr = 0.0;
      for (var i = 0; i < out.length; i++) {
        final d = (out[i] - reference[i]).toDouble();
        err += d * d;
        sig += reference[i] * reference[i];
        maxErr = math.max(maxErr, d.abs());
      }
      r['max_abs_diff'] = maxErr;
      // JSON has no infinity: identical outputs read as 300 dB.
      r['snr_vs_cpu_db'] = sig == 0 ? null : (err == 0 ? 300.0 : math.min(300.0, 10 * math.log(sig / err) / math.ln10));
    }
    if (provider.startsWith('CPU') && !_lastOutputs.containsKey(name)) _lastOutputs[name] = out;
  } catch (e) {
    r['error'] = '$e'.split('\n').first;
  } finally {
    await model?.close();
    r['peak_footprint_mb'] = memory.end();
    r['process_max_rss_mb'] = ProcessInfo.maxRss / 1e6;
  }
  final line = r['error'] != null
      ? '失败：${r['error']}'
      : '加载 ${r['load_s']} 秒，首次 ${r['first_run_s']} 秒，每次 ${(r['run_s'] as double).toStringAsFixed(3)} 秒'
            '${r['snr_vs_cpu_db'] != null ? '，与 CPU 差值比 ${(r['snr_vs_cpu_db'] as double).toStringAsFixed(1)} dB' : ''}'
            '，内存峰值 +${_mbValue(r['peak_footprint_mb'] as double?)}';
  log('$name · $provider：$line');
  return _Result(r);
}

String _mbValue(double? mb) => mb == null ? '未知' : '${mb.round()} MB';

/// One complete import through the app's own background job.
Future<Map<String, Object?>> _import(Directory tmp, String mdxPath, String vrPath) async {
  final r = <String, Object?>{'song_seconds': _songSeconds};
  final song = '${tmp.path}/bench-song.wav';
  writeWavFile(song, synthSong(_songSeconds.toDouble()), 2, 44100);
  final memory = _MemorySampler()..begin();
  final watch = Stopwatch()..start();
  final stages = <String, double>{};
  final estimates = <List<double>>[]; // [elapsed, estimated remaining]
  var lastLog = -10.0;
  try {
    final job = await ImportJob.start(
      ImportRequest(
        audioPath: song,
        lyrics: benchLyrics(_songSeconds.toDouble()),
        title: '测速',
        mdxModelPath: mdxPath,
        vrModelPath: vrPath,
        keepOriginal: false,
      ),
      '${tmp.path}/songs',
    );
    await for (final e in job.events) {
      final t = watch.elapsedMilliseconds / 1000;
      switch (e) {
        case ImportProgressEvent(:final progress):
          stages.putIfAbsent(progress.stage.label, () => t);
          final left = progress.remaining;
          if (left != null) estimates.add([t, left.inMilliseconds / 1000]);
          if (t - lastLog >= 10) {
            lastLog = t;
            log('导入 ${(progress.overall * 100).floor()}% ${progress.stage.label} '
                '${progress.done ?? ''}${progress.total == null ? '' : '/${progress.total}'}'
                '，已用 ${t.round()} 秒${left == null ? '' : '，预计还需 ${left.inSeconds} 秒'}');
          }
        case ImportDoneEvent(:final song):
          r['vr'] = song.modelInfo['vr'];
        case ImportFailedEvent(:final message):
          r['error'] = message;
      }
    }
  } catch (e) {
    r['error'] = '$e';
  }
  final total = watch.elapsedMilliseconds / 1000;
  r['total_s'] = total;
  r['realtime_factor'] = total / _songSeconds;
  r['peak_footprint_mb'] = memory.end();
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
  log('导入用时 ${total.round()} 秒（${(total / _songSeconds).toStringAsFixed(2)} 倍歌曲时长），'
      '去和声窗口：${r['vr'] ?? '–'}，内存峰值 +${_mbValue(r['peak_footprint_mb'] as double?)}');
  return r;
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
