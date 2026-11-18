import 'dart:async';
import 'dart:io';

import 'package:archive/archive_io.dart';
import 'package:flutter/foundation.dart';

import 'model_catalog.dart';
import 'model_downloader.dart';
import 'model_recipe.dart';

enum ModelPhase {
  /// Not on the device yet.
  missing,
  downloading,
  verifying,

  /// Assembling or extracting the verified model.
  preparing,
  ready,
  failed,
}

/// Downloads, verifies and installs models, and tells
/// the rest of the app where they are.
///
/// Each file is fetched from its first route ([ModelSpec.sources]:
/// hf-mirror.com, then UVR's repository on GitHub) that works: a route is
/// given up when it cannot be reached, hands the request on to another site
/// (see [ResumableDownload.fetch]), answers with an error, stops, stays too
/// slow or delivers a file with the wrong SHA-256. The next route continues
/// the partial file (the bytes are the same). Only when every route failed
/// is the download reported as failed. The route that worked is tried
/// first for the next file.
///
/// Files are only ever moved to their final name after their SHA-256 has
/// been checked, so "the file exists with the right size" means "installed".
class ModelManager extends ChangeNotifier {
  ModelManager({
    required this.dir,
    required this.loadRecipe,
    this.specs = separationModels,
    this.downloaderFactory = _defaultDownloader,
    this.excludeFromBackup,
  });

  final Directory dir;

  /// Loads the recipe that assembles the karaoke model (bundled asset).
  final Future<ModelRecipe> Function(ModelSpec spec) loadRecipe;
  final List<ModelSpec> specs;
  final ResumableDownload Function() downloaderFactory;

  /// Marks a path as "do not back up" (the models can be downloaded again).
  final void Function(String path)? excludeFromBackup;

  static ResumableDownload _defaultDownloader() => ResumableDownload();

  /// A route slower than this over half a minute is given up when another
  /// route is left (194 MB would take over an hour).
  static const slowRouteBytesPerSecond = 48 * 1024;

  ModelPhase _phase = ModelPhase.missing;
  String? _error;
  String? _errorDetail;
  int _received = 0;
  double _speed = 0;
  ModelSpec? _current;
  ResumableDownload? _download;
  Future<void>? _running;
  List<ModelSpec>? _requestedModels;

  /// Models in the current (or most recent) install operation.
  List<ModelSpec> get requestedModels => _requestedModels ?? specs;
  String? _route;
  int _routeIndex = 0;
  int _preferredRoute = 0;

  /// Test builds: the next [install] uses only the backup routes, to try
  /// them on a network where the main route works. Reset after it.
  bool backupOnly = false;

  ModelPhase get phase => isReady ? ModelPhase.ready : _phase;
  String? get error => _error;

  /// What went wrong on each route, when more than one was tried. Shown in
  /// test builds only.
  String? get errorDetail => _errorDetail;
  ModelSpec? get current => _current;
  bool get busy => _running != null;

  /// Host of the route the running download uses ("hf-mirror.com",
  /// "github.com"), and whether it is a backup route.
  String? get route => _route;
  bool get onBackupRoute => _route != null && _routeIndex > 0;

  /// Total catalog size, and byte counts for a requested subset.
  int get totalBytes => bytesFor(specs);
  int bytesFor(Iterable<ModelSpec> models) => models.fold(0, (s, m) => s + m.bytes);
  int get downloadTotalBytes => bytesFor(requestedModels);
  /// Bytes on disk (finished + partial) for the current install operation.
  int get receivedBytes => _received;

  /// Download speed in bytes per second (smoothed).
  double get bytesPerSecond => _speed;
  double get progress => downloadTotalBytes == 0 ? 0 : (_received / downloadTotalBytes).clamp(0.0, 1.0);

  bool isInstalled(ModelSpec spec) {
    final f = File(_installedPath(spec));
    if (spec.archive case final archive?) {
      return archive.files.entries.every((e) => _hasSize(File('${f.parent.path}/${e.key}'), e.value));
    }
    return _hasSize(f, spec.installedBytes);
  }

  static bool _hasSize(File file, int size) => file.existsSync() && file.lengthSync() == size;

  bool get isReady => isReadyFor(specs);
  bool isReadyFor(Iterable<ModelSpec> models) => models.every(isInstalled);

  /// Path of the installed ONNX model, or null.
  String? pathFor(ModelSpec spec) => isInstalled(spec) ? _installedPath(spec) : null;

  int get installedBytes => specs.where(isInstalled).fold(
      0, (s, m) => s + (m.archive?.files.values.fold<int>(0, (total, size) => total + size) ?? m.installedBytes));

  String _installedPath(ModelSpec spec) => '${dir.path}/${spec.installedName}';
  File _partFile(ModelSpec spec) => File('${dir.path}/${spec.fileName}.part');

  int _onDisk() => receivedBytesFor(requestedModels);

  int receivedBytesFor(Iterable<ModelSpec> models) {
    var n = 0;
    for (final spec in models) {
      if (isInstalled(spec)) {
        n += spec.bytes;
      } else {
        final part = _partFile(spec);
        if (part.existsSync()) n += part.lengthSync().clamp(0, spec.bytes);
      }
    }
    return n;
  }

  /// Downloads only the requested models (all models if omitted). Safe to
  /// call again after failure or cancellation: finished files are kept and
  /// partial ones resumed. A running operation keeps its original scope.
  Future<void> install({List<ModelSpec>? requiredModels}) {
    if (_running != null) return _running!;
    _requestedModels = List.unmodifiable(requiredModels ?? specs);
    return _running = _install().whenComplete(() {
      _running = null;
      backupOnly = false;
      notifyListeners();
    });
  }

  Future<void> _install() async {
    _error = null;
    _errorDetail = null;
    _received = _onDisk();
    _set(ModelPhase.downloading);
    try {
      await dir.create(recursive: true);
      excludeFromBackup?.call(dir.path);
      for (final spec in requestedModels) {
        if (isInstalled(spec)) continue;
        _current = spec;
        final original = File('${dir.path}/${spec.fileName}');
        if ((spec.needsAssembly || spec.archive != null) && _hasSize(original, spec.bytes)) {
          await _verifyAndInstall(spec, original.path, deleteSource: true);
          _received = _onDisk();
          continue;
        }
        await _fetchVerified(spec);
        await _installVerified(spec, _partFile(spec).path, deleteSource: true);
        _received = _onDisk();
      }
      // Previous releases used fixed-time ONNX files. They cannot be reused
      // as the new graph, and would otherwise waste 194 MB after an upgrade.
      _removeObsoleteModels();
      _current = null;
      _route = null;
      _set(isReady ? ModelPhase.ready : ModelPhase.missing);
    } on DownloadCancelled {
      _current = null;
      _route = null;
      _set(ModelPhase.missing);
    } on _RoutesFailed catch (e) {
      _fail(e.message, detail: e.detail);
    } on ModelDownloadException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(e is FileSystemException ? '写入文件失败，可能是存储空间不足' : '出错了：$e');
    }
  }

  /// Downloads [spec] into its partial file and checks its SHA-256, trying
  /// its routes in turn (the one that worked last time first).
  Future<void> _fetchVerified(ModelSpec spec) async {
    final sources = spec.sources;
    final order = backupOnly && sources.length > 1
        ? [for (var i = 1; i < sources.length; i++) i]
        : [
            if (_preferredRoute < sources.length) _preferredRoute,
            for (var i = 0; i < sources.length; i++)
              if (i != _preferredRoute) i,
          ];
    final failures = <String>[];
    for (final i in order) {
      final url = sources[i];
      final last = i == order.last;
      final part = _partFile(spec);
      _route = routeName(url);
      _routeIndex = i;
      _received = _onDisk();
      final base = _received - (part.existsSync() ? part.lengthSync().clamp(0, spec.bytes) : 0);
      _set(ModelPhase.downloading);
      final download = downloaderFactory();
      _download = download;
      final meter = _SpeedMeter();
      try {
        await download.fetch(
          Uri.parse(url),
          part,
          expectedBytes: spec.bytes,
          minBytesPerSecond: last ? 0 : slowRouteBytesPerSecond,
          // The main route has to serve the file itself: where it hands
          // the request on, the backup route is the better choice.
          stayOnSite: i == 0 && sources.length > 1,
          onProgress: (n) {
            _received = base + n;
            _speed = meter.update(n);
            _notifyThrottled();
          },
        );
      } on ModelStorageException {
        // The device, not the route: the next one would fail the same way,
        // and "check your network" would be the wrong advice.
        rethrow;
      } on ModelDownloadException catch (e) {
        // Keep the partial file: the next route continues it.
        failures.add('$_route：${e.message}');
        continue;
      } finally {
        _download = null;
        download.close();
      }
      _received = base + spec.bytes;
      if (await _matches(spec, part.path)) {
        _preferredRoute = i;
        return;
      }
      part.deleteSync();
      failures.add('$_route：${spec.fileName} 校验失败，文件不完整或不是原版');
    }
    if (failures.length == 1) {
      throw ModelDownloadException(failures.single.substring(failures.single.indexOf('：') + 1));
    }
    throw _RoutesFailed('模型下载不了，请检查网络后重试', failures.join('；'));
  }

  Future<bool> _matches(ModelSpec spec, String path) async {
    _set(ModelPhase.verifying);
    return await compute(sha256OfFileSync, path) == spec.sha256;
  }

  /// Checks [path] against [spec] and moves / assembles it into place.
  Future<void> _verifyAndInstall(ModelSpec spec, String path, {required bool deleteSource}) async {
    if (!await _matches(spec, path)) {
      if (deleteSource) File(path).deleteSync();
      throw ModelDownloadException('${spec.fileName} 校验失败，文件不完整或不是原版，请重新下载');
    }
    await _installVerified(spec, path, deleteSource: deleteSource);
  }

  /// Moves / assembles a verified file into place.
  Future<void> _installVerified(ModelSpec spec, String path, {required bool deleteSource}) async {
    final target = _installedPath(spec);
    final tmp = '$target.tmp';
    if (spec.archive case final archive?) {
      _set(ModelPhase.preparing);
      final installed = File(target).parent;
      final staging = Directory('${installed.path}.tmp');
      try {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
        staging.createSync();
        await compute(_extractArchive, (archive, path, staging.path));
        if (installed.existsSync()) installed.deleteSync(recursive: true);
        staging.renameSync(installed.path);
        if (deleteSource) File(path).deleteSync();
      } finally {
        if (staging.existsSync()) staging.deleteSync(recursive: true);
      }
    } else if (spec.needsAssembly) {
      _set(ModelPhase.preparing);
      final recipe = await loadRecipe(spec);
      if (recipe.sourceSha256 != spec.sha256) {
        throw ModelDownloadException('内置的模型配方和 ${spec.fileName} 不匹配');
      }
      final out = await compute(_assemble, (recipe, path, tmp));
      if (out != recipe.outputSha256) {
        File(tmp).deleteSync();
        throw ModelDownloadException('${spec.title}模型生成失败');
      }
      File(tmp).renameSync(target);
      if (deleteSource) File(path).deleteSync();
    } else if (deleteSource) {
      File(path).renameSync(target);
    } else {
      File(path).copySync(tmp);
      File(tmp).renameSync(target);
    }
  }

  /// Installs model files the user already has (picked in the Files app).
  /// Files are recognised by content, not by name. Returns how many of the
  /// given files were models.
  Future<int> importFiles(List<String> paths, {List<ModelSpec>? requiredModels}) async {
    if (busy) return 0;
    _requestedModels = List.unmodifiable(requiredModels ?? specs);
    final job = _importFiles(paths);
    _running = job.then((_) {}).whenComplete(() {
      _running = null;
      notifyListeners();
    });
    return job;
  }

  Future<int> _importFiles(List<String> paths) async {
    _error = null;
    _errorDetail = null;
    var installed = 0;
    try {
      await dir.create(recursive: true);
      excludeFromBackup?.call(dir.path);
      for (final path in paths) {
        final length = File(path).lengthSync();
        final spec = requestedModels.where((s) => s.bytes == length).firstOrNull;
        if (spec == null) continue;
        if (isInstalled(spec)) {
          installed++;
          continue;
        }
        _current = spec;
        await _verifyAndInstall(spec, path, deleteSource: false);
        final part = _partFile(spec);
        if (part.existsSync()) part.deleteSync();
        installed++;
      }
      _current = null;
      _received = _onDisk();
      _set(isReady ? ModelPhase.ready : ModelPhase.missing);
      if (installed == 0) {
        _fail('选的文件不是所需模型（${requestedModels.map((s) => s.fileName).join('、')}）');
      }
    } on ModelDownloadException catch (e) {
      _fail(e.message);
    } catch (e) {
      _fail(e is FileSystemException ? '读写文件失败，可能是存储空间不足' : '出错了：$e');
    }
    return installed;
  }

  /// Stops a running download (it can be resumed later).
  void cancel() => _download?.cancel();

  /// Removes the installed models and partial downloads.
  Future<void> deleteAll({Iterable<ModelSpec>? requiredModels}) async {
    cancel();
    await _running;
    for (final spec in requiredModels ?? specs) {
      for (final f in [File(_installedPath(spec)), _partFile(spec), File('${_installedPath(spec)}.tmp')]) {
        if (f.existsSync()) f.deleteSync();
      }
      if (spec.archive != null) {
        final dir = File(_installedPath(spec)).parent;
        for (final folder in [dir, Directory('${dir.path}.tmp')]) {
          if (folder.existsSync()) folder.deleteSync(recursive: true);
        }
      }
    }
    _removeObsoleteModels();
    _received = 0;
    _error = null;
    _errorDetail = null;
    _set(ModelPhase.missing);
  }

  void _removeObsoleteModels() {
    for (final old in ['UVR-MDX-NET-Voc_FT.onnx', '6_HP-Karaoke-UVR.onnx']) {
      if (specs.any((s) => s.installedName == old)) continue;
      final file = File('${dir.path}/$old');
      if (file.existsSync()) file.deleteSync();
    }
  }

  void _fail(String message, {String? detail}) {
    _current = null;
    _route = null;
    _error = message;
    _errorDetail = detail;
    _set(ModelPhase.failed);
  }

  void _set(ModelPhase p) {
    _phase = p;
    notifyListeners();
  }

  DateTime _lastNotify = DateTime.fromMillisecondsSinceEpoch(0);
  void _notifyThrottled() {
    final now = DateTime.now();
    if (now.difference(_lastNotify).inMilliseconds < 120) return;
    _lastNotify = now;
    notifyListeners();
  }
}

/// Every route of a file failed; [detail] says how, route by route.
class _RoutesFailed extends ModelDownloadException {
  _RoutesFailed(super.message, this.detail);
  final String detail;
}

String _assemble((ModelRecipe, String, String) job) => job.$1.assembleSync(job.$2, job.$3);

Future<void> _extractArchive((ModelArchive, String, String) job) async {
  final (spec, path, destination) = job;
  final input = InputFileStream(path);
  try {
    // The release archive has already passed SHA-256 verification. Only
    // extract the known files, streaming the ONNX weights to disk.
    final archive = ZipDecoder().decodeStream(input, throwOnError: true);
    for (final MapEntry(key: name, value: length) in spec.files.entries) {
      final entry = archive.findFile('${spec.folder}/$name');
      if (entry == null || !entry.isFile || entry.size != length) {
        throw ModelDownloadException('模型压缩包缺少 $name');
      }
      final output = OutputFileStream('$destination/$name');
      try {
        entry.writeContent(output);
        if (output.length != length) throw ModelDownloadException('解压 $name 失败');
      } finally {
        await output.close();
      }
    }
  } finally {
    await input.close();
  }
}

class _SpeedMeter {
  final _watch = Stopwatch()..start();
  int _lastBytes = -1;
  int _lastMicros = 0;
  double _speed = 0;

  double update(int bytes) {
    final now = _watch.elapsedMicroseconds;
    if (_lastBytes < 0) {
      _lastBytes = bytes;
      _lastMicros = now;
      return 0;
    }
    final dt = (now - _lastMicros) / 1e6;
    if (dt >= 0.5) {
      final inst = (bytes - _lastBytes) / dt;
      _speed = _speed == 0 ? inst : 0.6 * _speed + 0.4 * inst;
      _lastBytes = bytes;
      _lastMicros = now;
    }
    return _speed;
  }
}
