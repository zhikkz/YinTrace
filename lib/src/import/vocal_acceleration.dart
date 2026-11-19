import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import '../app/atomic_file.dart';
import '../app/licenses.dart';
import 'import_pipeline.dart';

/// Core ML options for the vocal model (UVR-MDX-NET-Voc_FT). On an iPhone
/// (iPhone18,3, iOS 27.0.1) the MLProgram format on the GPU ran one chunk in
/// 0.26 s against 0.76 s with 4 CPU threads, with the same result (109 dB
/// difference-to-CPU ratio) and about the same memory. With the Neural
/// Engine it took 0.98 s, slower than the CPU, so the compute units leave it
/// out. The karaoke model stays on the CPU: every Core ML set-up made iOS
/// close the app.
const vocalCoreMLOptions = {'ModelFormat': 'MLProgram', 'MLComputeUnits': 'CPUAndGPU'};

/// How one import runs its models (see the [ImportRequest] fields of the
/// same names).
class ImportAcceleration {
  const ImportAcceleration({this.coreML, this.marker, this.verify = false, this.speed = const {}});

  final Map<String, String>? coreML;
  final String? marker;
  final bool verify;
  final Map<String, double> speed;
}

/// Whether the vocal model runs with Core ML on this device, and how fast
/// this device ran both models before (for the remaining-time estimate).
///
/// Core ML is on unless the user turned it off or a check did:
/// - the first import on a device (and after an app or system update)
///   compares Core ML's output with the CPU's on one chunk. If they differ,
///   or Core ML fails, the song is finished on the CPU and Core ML stays off;
/// - a marker file exists while the Core ML session is created and runs its
///   first chunk. Finding it before the next import means the system closed
///   the app there, and Core ML stays off.
///
/// Turning the setting on again clears what a check decided.
class VocalAcceleration extends ChangeNotifier {
  VocalAcceleration(this.dir, {bool? supported}) : supported = supported ?? (Platform.isIOS || Platform.isMacOS);

  /// Always off and keeps nothing (tests, platforms without Core ML).
  VocalAcceleration.unavailable() : dir = null, supported = false;

  /// Where the state, the marker and Core ML's compiled model live (the
  /// app's support directory); null keeps nothing.
  final Directory? dir;

  /// Core ML exists here (Apple platforms).
  final bool supported;

  bool userEnabled = true;

  /// Why a check turned Core ML off, or null.
  String? disabledReason;

  /// [checkKey] of the last check that passed.
  String? checkedFor;

  /// What the last check reported, e.g. `checked 109.0 dB`.
  String? lastCheck;

  /// Seconds per model run measured on this device ('mdx.cpu', 'mdx.coreml',
  /// 'vr.512', 'vr.320').
  final Map<String, double> speed = {};

  static const crashedReason = '上次用它分离人声时 App 被系统关闭了';

  bool get active => supported && userEnabled && disabledReason == null;

  /// A check holds for one app version on one system version.
  static String get checkKey => '$appVersion · ${Platform.operatingSystemVersion}';

  File? get _file => dir == null ? null : File('${dir!.path}/acceleration.json');
  late final LatestStateWriter? _writer = switch (_file) {
    final file? => LatestStateWriter(file, () => jsonEncode(toJson())),
    null => null,
  };
  File? get _marker => dir == null ? null : File('${dir!.path}/coreml-trial');

  static Future<VocalAcceleration> load(Directory dir, {bool? supported}) async {
    final a = VocalAcceleration(dir, supported: supported);
    try {
      final f = a._file!;
      if (await f.exists()) a._apply(jsonDecode(await f.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // Unreadable: start over with the defaults.
    }
    return a;
  }

  void _apply(Map<String, dynamic> j) {
    userEnabled = j['userEnabled'] as bool? ?? true;
    disabledReason = j['disabledReason'] as String?;
    checkedFor = j['checkedFor'] as String?;
    lastCheck = j['lastCheck'] as String?;
    final s = j['speed'];
    if (s is Map) {
      for (final e in s.entries) {
        final v = e.value;
        if (v is num && v > 0) speed['${e.key}'] = v.toDouble();
      }
    }
  }

  Map<String, Object?> toJson() => {
    'userEnabled': userEnabled,
    'disabledReason': disabledReason,
    'checkedFor': checkedFor,
    'lastCheck': lastCheck,
    'speed': speed,
  };

  Future<void> _save() async {
    notifyListeners();
    try {
      await _writer?.save();
    } catch (_) {}
  }

  /// Decides how the next import runs its models. [vocalModelPath] is the
  /// installed vocal model (its size and date name Core ML's cache).
  /// [anotherImportRunning] means the marker may belong to a live worker.
  Future<ImportAcceleration> beforeImport(String vocalModelPath, {bool anotherImportRunning = false}) async {
    final marker = _marker;
    if (!anotherImportRunning && marker != null && marker.existsSync()) {
      try {
        marker.deleteSync();
      } catch (_) {}
      if (active) {
        disabledReason = crashedReason;
        lastCheck = 'app closed';
        await _save();
      }
    }
    if (!active) return ImportAcceleration(speed: Map.of(speed));
    final cache = await _cacheFor(vocalModelPath);
    return ImportAcceleration(
      coreML: {...vocalCoreMLOptions, 'ModelCacheDirectory': ?cache},
      marker: marker?.path,
      verify: checkedFor != checkKey,
      speed: Map.of(speed),
    );
  }

  /// Core ML's compiled model, kept between imports so that it is compiled
  /// once (about 2 s on the iPhone). The folder is named after the model
  /// file's size and date: a changed model never meets an old compiled one.
  Future<String?> _cacheFor(String modelPath) async {
    final d = dir;
    if (d == null) return null;
    try {
      final stat = await File(modelPath).stat();
      final root = Directory('${d.path}/coreml-cache');
      final cache = Directory('${root.path}/vocals-${stat.size}-${stat.modified.millisecondsSinceEpoch}');
      if (!await cache.exists()) {
        if (await root.exists()) await root.delete(recursive: true);
        await cache.create(recursive: true);
      }
      return cache.path;
    } catch (_) {
      return null;
    }
  }

  /// Takes in what an import reported (see [ImportPipeline.coreMLInfo]).
  Future<void> afterImport(Map<String, String> info) async {
    final outcome = info[ImportPipeline.coreMLInfo];
    if (outcome != null) {
      lastCheck = outcome;
      if (outcome.startsWith('checked')) {
        checkedFor = checkKey;
      } else {
        disabledReason = _reasonFor(outcome);
      }
    }
    void record(String key, String? value) {
      final s = double.tryParse(value ?? '');
      if (s == null || !s.isFinite || s <= 0) return;
      final old = speed[key];
      speed[key] = old == null ? s : (old + s) / 2;
    }

    record(ImportPipeline.mdxSpeedKey(coreML: info['mdxRuntime'] == 'Core ML'), info['mdxRunSeconds']);
    final window = int.tryParse(info['vrWindow'] ?? '');
    if (window != null) record(ImportPipeline.vrSpeedKey(window), info['vrRunSeconds']);
    await _save();
  }

  /// The user's switch. Turning it on clears what a check decided and
  /// checks again on the next import.
  Future<void> setEnabled(bool on) async {
    userEnabled = on;
    if (on) {
      disabledReason = null;
      checkedFor = null;
    }
    await _save();
  }

  static String _reasonFor(String outcome) {
    if (outcome.startsWith('mismatch')) return '它算出的结果和 CPU 不一致';
    if (outcome.startsWith('invalid')) return '它算出了无效的数值';
    return '它出错了（${outcome.replaceFirst('error: ', '')}）';
  }

  /// One line for the settings page.
  String get status {
    if (!userEnabled) return '关闭时人声分离只用 CPU，会慢一些';
    final reason = disabledReason;
    if (reason != null) return '已自动关闭：$reason。打开后下次导入会再检查一次';
    if (checkedFor == checkKey) {
      final cpu = speed['mdx.cpu'], gpu = speed['mdx.coreml'];
      return '在这台设备上和 CPU 对比过，结果一致'
          '${cpu != null && gpu != null ? '，人声分离快 ${(cpu / gpu).toStringAsFixed(1)} 倍' : ''}';
    }
    return '下次导入时先和 CPU 对比一次，结果一致才用';
  }
}
