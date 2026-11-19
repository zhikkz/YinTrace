import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/aligner.dart';
import '../analysis/hubertfa_aligner.dart';
import '../analysis/lrc.dart';
import '../analysis/manual_timing.dart';
import '../analysis/pitch_track.dart';
import '../analysis/reference.dart';
import '../audio/audio_backend.dart';
import '../dsp/swift_f0.dart';
import '../library/song.dart';
import '../library/song_repository.dart';
import '../models/pitch_model.dart';
import '../separation/mdx_separator.dart';
import '../separation/model_config.dart';
import '../separation/tensor_model.dart';
import '../separation/vr_separator.dart';
import 'hubertfa_job.dart';

enum ImportStage {
  decoding('读取音频'),
  separatingVocals('分离人声'),
  removingHarmony('去掉和声'),
  analyzingPitch('测量音高'),
  aligning('逐句对齐歌词'),
  saving('保存到曲库');

  const ImportStage(this.label);
  final String label;
}

class ImportRequest {
  const ImportRequest({
    required this.audioPath,
    required this.lyrics,
    required this.title,
    this.artist = '',
    this.vocalsOnly = false,
    this.accompanimentPath,
    this.mdxModelPath,
    this.vrModelPath,
    this.keepOriginal = false,
    this.mdxCoreML,
    this.coreMLMarker,
    this.verifyCoreML = false,
    this.speed = const {},
    this.pitchModelPath,
    this.hubertFaPath,
  });

  /// The song (or, with [vocalsOnly], an already separated vocal).
  final String audioPath;

  /// Timed lyrics in LRC format.
  final String lyrics;
  final String title;
  final String artist;

  /// Skip separation: [audioPath] already is the pure lead vocal.
  final bool vocalsOnly;

  /// Optional accompaniment to practise with when [vocalsOnly] is set.
  final String? accompanimentPath;
  final String? mdxModelPath;

  /// Null skips the harmony removal: the MDX vocals are used directly.
  final String? vrModelPath;

  /// Also copy the imported file into the song's directory. Off: nothing
  /// reads that copy (practice plays the separated accompaniment), a FLAC
  /// or WAV of a song is 30-50 MB, and the directory is backed up.
  final bool keepOriginal;

  /// Core ML options for the vocal model, or null for the CPU. Whatever goes
  /// wrong with Core ML, the song is finished on the CPU (see
  /// [ImportPipeline.coreMLInfo] for what is reported back).
  final Map<String, String>? mdxCoreML;

  /// A file that exists while the Core ML session is created and runs its
  /// first chunk: finding it later means the system closed the app there.
  final String? coreMLMarker;

  /// Compare Core ML's first chunk with the CPU's and keep Core ML only if
  /// they agree (once per device, app version and system version).
  final bool verifyCoreML;

  /// Seconds per model run this device measured before ('mdx.cpu',
  /// 'mdx.coreml', 'vr.512', 'vr.320'), for the remaining-time estimate.
  final Map<String, double> speed;

  /// The pitch model ([PitchModel]) that measures the vocal's pitch; null,
  /// or a model that fails: YIN does.
  final String? pitchModelPath;

  /// The verified HuBERTFA ONNX file. Null keeps the offline aligner for
  /// callers that run the pipeline without the model, such as DSP tests.
  final String? hubertFaPath;

  Map<String, Object?> toMap() => {
    'audioPath': audioPath,
    'lyrics': lyrics,
    'title': title,
    'artist': artist,
    'vocalsOnly': vocalsOnly,
    'accompanimentPath': accompanimentPath,
    'mdxModelPath': mdxModelPath,
    'vrModelPath': vrModelPath,
    'keepOriginal': keepOriginal,
    'mdxCoreML': mdxCoreML,
    'coreMLMarker': coreMLMarker,
    'verifyCoreML': verifyCoreML,
    'speed': speed,
    'pitchModelPath': pitchModelPath,
    'hubertFaPath': hubertFaPath,
  };

  factory ImportRequest.fromMap(Map<Object?, Object?> m) => ImportRequest(
    audioPath: m['audioPath'] as String,
    lyrics: m['lyrics'] as String,
    title: m['title'] as String,
    artist: m['artist'] as String? ?? '',
    vocalsOnly: m['vocalsOnly'] as bool? ?? false,
    accompanimentPath: m['accompanimentPath'] as String?,
    mdxModelPath: m['mdxModelPath'] as String?,
    vrModelPath: m['vrModelPath'] as String?,
    keepOriginal: m['keepOriginal'] as bool? ?? false,
    mdxCoreML: (m['mdxCoreML'] as Map?)?.cast<String, String>(),
    coreMLMarker: m['coreMLMarker'] as String?,
    verifyCoreML: m['verifyCoreML'] as bool? ?? false,
    speed: {
      for (final e in ((m['speed'] as Map?) ?? const {}).entries) e.key as String: (e.value as num).toDouble(),
    },
    pitchModelPath: m['pitchModelPath'] as String?,
    hubertFaPath: m['hubertFaPath'] as String?,
  );
}

class ImportProgress {
  const ImportProgress(this.stage, this.stageFraction, this.overall, {this.done, this.total, this.remaining});
  final ImportStage stage;
  final double stageFraction;

  /// Fraction of the whole import, weighted by the work of each stage.
  final double overall;

  /// Model runs finished and needed in a separation stage.
  final int? done;
  final int? total;

  /// Estimated time still needed, from how fast this device has worked so
  /// far; null until that is known.
  final Duration? remaining;

  Map<String, Object?> toMap() => {
    'stage': stage.index,
    'stageFraction': stageFraction,
    'overall': overall,
    'done': done,
    'total': total,
    'remainingMs': remaining?.inMilliseconds,
  };

  factory ImportProgress.fromMap(Map<Object?, Object?> m) {
    final ms = m['remainingMs'] as int?;
    return ImportProgress(
      ImportStage.values[m['stage'] as int],
      (m['stageFraction'] as num).toDouble(),
      (m['overall'] as num).toDouble(),
      done: m['done'] as int?,
      total: m['total'] as int?,
      remaining: ms == null ? null : Duration(milliseconds: ms),
    );
  }
}

/// Loads a model on the CPU, or with [coreML] options through Core ML.
typedef ModelLoader = Future<TensorModel> Function(
  String path, {
  required String inputName,
  required String outputName,
  Map<String, String>? coreML,
});

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns an audio file + timed lyrics into a practice-ready song.
class ImportPipeline {
  ImportPipeline({
    required this.audio,
    required this.loadModel,
    required this.repository,
    this.availableMemory,
  });

  final AudioBackend audio;
  final ModelLoader loadModel;
  final SongRepository repository;

  /// Bytes the process can still allocate before the system ends it, or
  /// null when unknown (see [vrWindowFor]).
  final int? Function()? availableMemory;

  /// Memory ONNX Runtime needs for the karaoke model with UVR's 512-frame
  /// window, beyond what the 320-frame window needs (desktop measurement:
  /// 1013 vs 834 MB peak).
  static const _vr512Bytes = 1050 * 1000 * 1000;

  /// The karaoke model's window for a song of [samples] stereo samples.
  ///
  /// UVR's 512 frames needs a quarter of the model runs of 320, so it is
  /// much faster. When the system reports less free memory than 512 needs
  /// (the model, the separated song and one segment's spectrograms, with a
  /// margin), use 320 instead so that phones with little memory still work.
  static int vrWindowFor(int? availableBytes, int samples) {
    if (availableBytes == null) return 512;
    final need = _vr512Bytes + samples * 2 * 4 + 300 * 1000 * 1000;
    return availableBytes >= need ? 512 : 320;
  }

  /// Seconds per model run inside the import, used until this device has
  /// measured its own ([ImportRequest.speed]). From an iPhone (iPhone18,3,
  /// iOS 27.0.1) importing a 4-minute song: MDX on the CPU 94.9 s for 110
  /// runs, VR 512 135.1 s for 96 runs (a little of it before the first run).
  /// With Core ML one MDX run took 0.26 s instead of 0.76 s in the
  /// benchmark; the tensor copies and STFT around it (0.11 s) stay. VR 320:
  /// 0.77 s against 1.19 s per run for 512 in the benchmark.
  static const defaultRunSeconds = {'mdx.cpu': 0.86, 'mdx.coreml': 0.37, 'vr.512': 1.35, 'vr.320': 0.87};

  /// The keys of [ImportRequest.speed] and [defaultRunSeconds].
  static String mdxSpeedKey({required bool coreML}) => coreML ? 'mdx.coreml' : 'mdx.cpu';
  static String vrSpeedKey(int window) => window >= 512 ? 'vr.512' : 'vr.320';

  /// What an import reports in [SongMeta.modelInfo] about the vocal model
  /// and the speed of both models:
  /// - `mdxRuntime`: `Core ML` or `CPU` (what separated most of the song);
  /// - `coreML`: `checked <dB> dB` when Core ML agreed with the CPU, else
  ///   why the song was finished on the CPU: `error: ...`, `invalid output`
  ///   or `mismatch <dB> dB`;
  /// - `mdxRunSeconds`, `vrRunSeconds`, `vrWindow`: measured per model run.
  static const coreMLInfo = 'coreML';

  Future<SongMeta> run(
    ImportRequest r, {
    void Function(ImportProgress)? onProgress,
    bool Function()? isCancelled,
  }) async {
    final lrc = parseLrc(r.lyrics);
    if (lrc.lines.isEmpty) {
      throw ImportException('没有解析到带时间的歌词，请按 [mm:ss.xx]歌词 的格式输入');
    }
    final separate = !r.vocalsOnly;
    if (separate && r.mdxModelPath == null) {
      throw ImportException('还没有下载人声分离模型');
    }
    _ImportClock? clock;
    void report(ImportStage stage, double f, {int? done, int? total}) {
      if (isCancelled?.call() ?? false) throw const SeparationCancelled();
      final c = clock;
      onProgress?.call(
        c == null ? ImportProgress(stage, f, 0) : c.update(stage, f, done: done, total: total),
      );
    }

    final id = repository.newSongId();
    final dir = repository.dirFor(id);
    try {
      report(ImportStage.decoding, 0);
      var mix = audio.decode(r.audioPath, sampleRate: 44100, channels: 2).samples;
      final frames = mix.length ~/ 2;
      final duration = frames / 44100;
      if (frames < 44100) throw ImportException('音频太短');

      const mdxCfg = MdxConfig.vocFt;
      var vrCfg = VrConfig.karaoke6Hp;
      final harmony = separate && r.vrModelPath != null;
      if (harmony) {
        vrCfg = vrCfg.withWindowSize(vrWindowFor(availableMemory?.call(), frames));
      }
      final mdx = MdxSeparator(_NoModel.instance, mdxCfg);
      final vr = VrSeparator(_NoModel.instance, vrCfg);
      double runSeconds(String key) => r.speed[key] ?? defaultRunSeconds[key]!;
      // Each stage weighs the seconds it takes on the iPhone above, or as
      // this device measured before: the progress bar, and the remaining
      // time until the current stage's own speed is measured.
      clock = _ImportClock({
        ImportStage.decoding: 0.003 * duration,
        if (separate)
          ImportStage.separatingVocals:
              mdx.chunkCount(frames) * runSeconds(mdxSpeedKey(coreML: r.mdxCoreML != null)),
        if (harmony)
          ImportStage.removingHarmony:
              (vr.inferenceCount(frames) + 0.3 * vr.segmentCount(frames)) * runSeconds(vrSpeedKey(vrCfg.windowSize)),
        // Pitch and saving take about 4.0 s and 1.2 s for a 4-minute song.
        ImportStage.analyzingPitch: 0.017 * duration,
        ImportStage.aligning: r.hubertFaPath == null ? 0.004 * duration : 2 + 0.18 * duration,
        ImportStage.saving: 0.005 * duration,
      });
      report(ImportStage.decoding, 1);

      Float32List vocals; // stereo
      Float32List? accompaniment;
      final modelInfo = <String, String>{};
      if (separate) {
        final model = await _vocalModel(r, mdxCfg, modelInfo);
        final timer = _RunTimer();
        try {
          vocals = await MdxSeparator(model, mdxCfg).separate(
            mix,
            onStep: (done, total) {
              timer.step(done);
              report(ImportStage.separatingVocals, done / total, done: done, total: total);
            },
          );
        } finally {
          await model.close();
        }
        modelInfo['mdx'] = mdxCfg.name;
        if (timer.secondsPerRun case final s?) modelInfo['mdxRunSeconds'] = s.toStringAsFixed(3);
        if (harmony) {
          // Keep only the MDX vocals while VR owns its large working set.
          // Re-decode the local source after closing VR to make accompaniment;
          // decoding twice costs far less memory than retaining a whole mix.
          mix = Float32List(0);
          final model = await loadModel(r.vrModelPath!, inputName: vrCfg.inputName, outputName: vrCfg.outputName);
          final timer = _RunTimer();
          try {
            var done = 0;
            final runs = vr.inferenceCount(frames);
            // The karaoke model's secondary stem is the lead vocal.
            vocals = await VrSeparator(model, vrCfg).separate(
              vocals,
              stem: VrStem.secondary,
              onStep: (d, _) {
                done = d;
                timer.step(d);
              },
              onProgress: (f) => report(ImportStage.removingHarmony, f, done: done, total: runs),
            );
            modelInfo['vr'] = vrCfg.windowSize == 512 ? vrCfg.name : '${vrCfg.name} (window ${vrCfg.windowSize})';
            modelInfo['vrWindow'] = '${vrCfg.windowSize}';
            if (timer.secondsPerRun case final s?) modelInfo['vrRunSeconds'] = s.toStringAsFixed(3);
          } finally {
            await model.close();
          }
        }
        if (mix.isEmpty) {
          mix = audio.decode(r.audioPath, sampleRate: 44100, channels: 2).samples;
          if (mix.length != vocals.length) {
            throw ImportException('处理期间音频长度发生了变化，请重新选择文件导入');
          }
        }
        // Reuse the decoded mixture after both models are done. No third
        // song-length stereo buffer for the accompaniment.
        for (var i = 0; i < mix.length; i++) {
          mix[i] -= vocals[i];
        }
        accompaniment = mix;
      } else {
        vocals = mix;
        if (r.accompanimentPath != null) {
          accompaniment = _fitLength(
            audio.decode(r.accompanimentPath!, sampleRate: 44100, channels: 2).samples,
            vocals.length,
          );
        }
      }

      final mono = Float32List(vocals.length ~/ 2);
      for (var i = 0; i < mono.length; i++) {
        mono[i] = 0.5 * (vocals[2 * i] + vocals[2 * i + 1]);
      }
      // The rest of the pipeline only needs mono vocals and accompaniment.
      // Drop both aliases, including the pure-vocal input case.
      vocals = Float32List(0);
      mix = Float32List(0);
      // The pitch is measured on the separated lead vocal (or the vocal-only
      // file), never on the mix.
      report(ImportStage.analyzingPitch, 0);
      final track = await _pitchTrack(r, mono, modelInfo, (f) => report(ImportStage.analyzingPitch, f));
      report(ImportStage.aligning, 0);
      final modelPath = r.hubertFaPath;
      SongReference? aligned;
      if (modelPath != null) {
        try {
          aligned = await HubertFaAligner.withModel(modelPath, lrc.lines, (aligner) => aligner.alignSong(
            mono, track, lrc.lines, onProgress: (done, total) {
              report(ImportStage.aligning, done / total, done: done, total: total);
            },
          ));
        } on SeparationCancelled {
          rethrow;
        } catch (e) {
          modelInfo['alignmentModelError'] = '$e'.split('\n').first;
        }
      }
      modelInfo['alignment'] = aligned == null ? '音高轨迹' : 'HuBERTFA';
      final reference = aligned ?? buildReference(track, lrc.lines);
      report(ImportStage.aligning, 1);

      report(ImportStage.saving, 0);
      final vocalsPath = audio.writeCompressed('${dir.path}/vocals', mono, 1, 44100, bitrate: 96000);
      report(ImportStage.saving, 0.4);
      String? accPath;
      if (accompaniment != null) {
        accPath = audio.writeCompressed(
          '${dir.path}/accompaniment',
          accompaniment,
          2,
          44100,
          bitrate: 192000,
        );
      }
      report(ImportStage.saving, 0.8);
      String? originalName;
      if (r.keepOriginal && separate) {
        final ext = _extension(r.audioPath);
        originalName = 'original$ext';
        await File(r.audioPath).copy('${dir.path}/$originalName');
      }
      await repository.savePitchTrack(id, track);
      await repository.saveReference(id, reference);
      final meta = SongMeta(
        id: id,
        title: r.title.trim().isEmpty ? '未命名歌曲' : r.title.trim(),
        artist: r.artist.trim(),
        createdAt: DateTime.now(),
        duration: duration,
        lyrics: r.lyrics,
        vocalsFile: _name(vocalsPath),
        accompanimentFile: accPath == null ? null : _name(accPath),
        originalFile: originalName,
        separated: separate,
        modelInfo: modelInfo,
      );
      await repository.save(meta);
      report(ImportStage.saving, 1);
      return meta;
    } catch (_) {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      rethrow;
    }
  }

  /// The vocal model: with Core ML when the request asks for it, guarded so
  /// that the song is finished on the CPU whatever goes wrong.
  Future<TensorModel> _vocalModel(ImportRequest r, MdxConfig cfg, Map<String, String> info) async {
    Future<TensorModel> cpu() => loadModel(r.mdxModelPath!, inputName: cfg.inputName, outputName: cfg.outputName);
    info['mdxRuntime'] = 'CPU';
    final options = r.mdxCoreML;
    if (options == null) return cpu();
    final marker = r.coreMLMarker == null ? null : File(r.coreMLMarker!);
    try {
      marker?.writeAsStringSync(DateTime.now().toIso8601String(), flush: true);
    } catch (_) {}
    try {
      final model = await loadModel(
        r.mdxModelPath!,
        inputName: cfg.inputName,
        outputName: cfg.outputName,
        coreML: options,
      );
      info['mdxRuntime'] = 'Core ML';
      return _CoreMLGuard(model, cpu, verifyPending: r.verifyCoreML, marker: marker, info: info);
    } catch (e) {
      _CoreMLGuard.removeMarker(marker);
      info[coreMLInfo] = 'error: ${'$e'.split('\n').first}';
      return cpu();
    }
  }

  /// What [SongMeta.modelInfo] says measured the vocal's pitch (`pitch`:
  /// the pitch model's name, or `YIN`), and why the model was not used when
  /// the request had one (`pitchModelError`).
  static const pitchInfo = 'pitch';

  /// The pitch of [vocal] (mono, 44.1 kHz: the separated lead vocal, or the
  /// vocal-only file), measured with the pitch model, or with YIN when the
  /// request has none or the model fails (the song is finished with YIN).
  Future<PitchTrack> _pitchTrack(
    ImportRequest r,
    Float32List vocal,
    Map<String, String> info,
    void Function(double) onProgress,
  ) async {
    final path = r.pitchModelPath;
    if (path != null) {
      TensorModel? model;
      try {
        model = await loadModel(path, inputName: PitchModel.inputName, outputName: PitchModel.outputName);
        final track = await analyzePitchWithModel(vocal, 44100, SwiftF0(model), onProgress: onProgress);
        info[pitchInfo] = PitchModel.name;
        return track;
      } on SeparationCancelled {
        rethrow;
      } catch (e) {
        info['pitchModelError'] = '$e'.split('\n').first;
      } finally {
        try {
          await model?.close();
        } catch (_) {}
      }
    }
    info[pitchInfo] = 'YIN';
    return analyzePitch(vocal, 44100, onProgress: onProgress);
  }

  static String _name(String path) => path.split(Platform.pathSeparator).last.split('/').last;

  static String _extension(String path) {
    final name = _name(path);
    final dot = name.lastIndexOf('.');
    return dot > 0 ? name.substring(dot).toLowerCase() : '';
  }

  static Float32List _fitLength(Float32List x, int length) {
    if (x.length == length) return x;
    final out = Float32List(length);
    out.setRange(0, x.length < length ? x.length : length, x);
    return out;
  }
}

/// Only for counting the work of a separator before its model is loaded.
class _NoModel implements TensorModel {
  static final instance = _NoModel();
  @override
  Future<Float32List> run(Float32List input, List<int> shape) => throw UnsupportedError('no model');
  @override
  Future<void> close() async {}
}

/// Runs the vocal model with Core ML, and finishes the song on the CPU when
/// Core ML fails, returns values that are not finite or, on the checked
/// chunk, does not agree with the CPU. The marker file is removed once the
/// first chunk is back (or Core ML is given up).
class _CoreMLGuard implements TensorModel {
  _CoreMLGuard(this._coreML, this._loadCpu, {required this.verifyPending, required this.marker, required this.info});

  /// Difference-to-CPU ratio Core ML must reach (it measured 109 dB on an
  /// iPhone; computing in 16-bit floats would still be far above this).
  static const minAgreementDb = 40.0;

  TensorModel? _coreML;
  TensorModel? _cpu;
  final Future<TensorModel> Function() _loadCpu;
  final File? marker;
  final Map<String, String> info;

  /// The comparison with the CPU is still to be made.
  bool verifyPending;
  bool _first = true;
  bool _closed = false;

  static void removeMarker(File? marker) {
    try {
      if (marker != null && marker.existsSync()) marker.deleteSync();
    } catch (_) {}
  }

  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    final coreML = _coreML;
    if (coreML == null) return _cpu!.run(input, shape);
    final Float32List out;
    try {
      out = await coreML.run(input, shape);
    } catch (e) {
      if (_closed) rethrow;
      return _fallBack(input, shape, 'error: ${'$e'.split('\n').first}');
    }
    // Closed meanwhile (the import was stopped): nobody wants this chunk.
    if (_closed) return out;
    if (_first) {
      _first = false;
      removeMarker(marker);
    }
    if (!_allFinite(out)) return _fallBack(input, shape, 'invalid output');
    // Compare on a chunk with sound in it: silence agrees with anything.
    if (verifyPending && _hasSound(input)) {
      verifyPending = false;
      final cpu = await _loadCpu();
      final Float32List reference;
      try {
        reference = await cpu.run(input, shape);
      } finally {
        await cpu.close();
      }
      final db = agreementDb(reference, out);
      if (db < minAgreementDb) {
        return _fallBack(input, shape, 'mismatch ${db.toStringAsFixed(1)} dB', reference: reference);
      }
      info[ImportPipeline.coreMLInfo] = 'checked ${db.toStringAsFixed(1)} dB';
    }
    return out;
  }

  Future<Float32List> _fallBack(Float32List input, List<int> shape, String reason, {Float32List? reference}) async {
    removeMarker(marker);
    info[ImportPipeline.coreMLInfo] = reason;
    info['mdxRuntime'] = 'CPU';
    final coreML = _coreML;
    _coreML = null;
    try {
      await coreML?.close();
    } catch (_) {}
    final cpu = _cpu ??= await _loadCpu();
    return reference ?? await cpu.run(input, shape);
  }

  @override
  Future<void> close() async {
    // Closed normally (also when the import was cancelled before the first
    // chunk came back): no sign of the system closing the app.
    removeMarker(marker);
    _closed = true;
    final coreML = _coreML, cpu = _cpu;
    _coreML = null;
    _cpu = null;
    await coreML?.close();
    await cpu?.close();
  }

  static bool _allFinite(Float32List x) {
    for (var i = 0; i < x.length; i++) {
      if (!x[i].isFinite) return false;
    }
    return true;
  }

  static bool _hasSound(Float32List x) {
    for (var i = 0; i < x.length; i++) {
      if (x[i].abs() > 1e-3) return true;
    }
    return false;
  }
}

/// Signal-to-difference ratio of [test] against [reference], in dB (300 for
/// identical outputs).
double agreementDb(Float32List reference, Float32List test) {
  if (reference.length != test.length) return double.negativeInfinity;
  var sig = 0.0, err = 0.0;
  for (var i = 0; i < reference.length; i++) {
    final d = (test[i] - reference[i]).toDouble();
    err += d * d;
    sig += reference[i] * reference[i];
  }
  if (err == 0) return 300;
  if (sig == 0) return double.negativeInfinity;
  return math.min(300, 10 * math.log(sig / err) / math.ln10);
}

/// Seconds per model run, from the first finished run to the last one (the
/// first run includes loading the model, with Core ML compiling it).
class _RunTimer {
  final _watch = Stopwatch()..start();
  Duration? _first;
  Duration _last = Duration.zero;
  int _firstDone = 0;
  int _lastDone = 0;

  void step(int done) {
    if (done < 1) return;
    final now = _watch.elapsed;
    if (_first == null) {
      _first = now;
      _firstDone = done;
    }
    _last = now;
    _lastDone = done;
  }

  double? get secondsPerRun {
    final first = _first;
    if (first == null || _lastDone - _firstDone < 2) return null;
    return (_last - first).inMicroseconds / 1e6 / (_lastDone - _firstDone);
  }
}

/// Weighs the stages of an import by their work and estimates the time
/// left from how fast this device has actually been working.
///
/// Work is counted in the seconds a stage takes on a reference iPhone, or
/// as this device measured before ([ImportPipeline.defaultRunSeconds]). The
/// remaining time uses the rate of the current stage once it has run for a
/// while (its first seconds include loading a model), else the rate of the
/// stage before it.
class _ImportClock {
  _ImportClock(this.units) : total = units.values.fold(0.0, (a, b) => a + b);

  final Map<ImportStage, double> units;
  final double total;
  final _watch = Stopwatch()..start();

  ImportStage? _stage;
  Duration _stageStart = Duration.zero;
  double _before = 0; // units of the stages before the current one
  double _done = 0;
  double? _markUnits; // where the rate measurement of this stage starts
  Duration _markTime = Duration.zero;
  double? _rate; // units per second

  /// Without model runs, start measuring this long into a stage.
  static const _warmUp = Duration(seconds: 3);

  ImportProgress update(ImportStage stage, double fraction, {int? done, int? total}) {
    final now = _watch.elapsed;
    if (stage != _stage) {
      _stage = stage;
      _stageStart = now;
      _before = 0;
      for (final s in ImportStage.values) {
        if (s == stage) break;
        _before += units[s] ?? 0;
      }
      _markUnits = null;
    }
    _done = math.max(_done, _before + (units[stage] ?? 0) * fraction.clamp(0.0, 1.0));
    final mark = _markUnits;
    if (mark == null) {
      // A stage's first model run includes loading the model.
      final ready = total != null ? (done ?? 0) >= 1 : now - _stageStart >= _warmUp;
      if (ready) {
        _markUnits = _done;
        _markTime = now;
      }
    } else if (now - _markTime >= const Duration(seconds: 2) && _done > mark) {
      _rate = (_done - mark) / ((now - _markTime).inMicroseconds / 1e6);
    }
    final rate = _rate;
    return ImportProgress(
      stage,
      fraction,
      this.total > 0 ? (_done / this.total).clamp(0.0, 1.0) : fraction,
      done: done,
      total: total,
      remaining: rate == null || rate <= 0
          ? null
          : Duration(milliseconds: ((this.total - _done) / rate * 1000).round()),
    );
  }
}

/// Re-aligns an existing song after its lyrics changed (no re-separation).
///
/// Lines whose words did not change keep the user's corrections (pitch,
/// and starts set by hand) and their practice scores, also when lines were
/// added or removed before them and they moved; the scores of removed and
/// rewritten lines are dropped.
///
/// With HuBERTFA and [pitchModelPath], the pitch of the stored vocal is
/// measured again first, so that a song imported with an older version of
/// the app (or from a song file) gets the pitch curve this version measures.
Future<void> realignSong(SongRepository repo, String id, String lyrics, {
  String? hubertFaPath,
  String? pitchModelPath,
  void Function(int, int)? onProgress,
  bool Function()? isCancelled,
  void Function()? onSaving,
}) async {
  final lrc = parseLrc(lyrics);
  if (lrc.lines.isEmpty) throw ImportException('没有解析到带时间的歌词');
  final track = await repo.loadPitchTrack(id);
  final meta = await repo.load(id);
  SongReference? old;
  try {
    old = await repo.loadReference(id);
  } catch (_) {
    // No earlier reference to take corrections from.
  }
  final pins = old == null ? const <(int, int), double>{} : carriedPins(old, lrc.lines);
  final readings = old == null ? const <(int, int), String>{} : carriedPinyin(old, lrc.lines);
  final (reference, measured) = hubertFaPath == null
      ? (buildReference(track, lrc.lines, pins: pins), null)
      : await alignStoredVocal(
          hubertFaPath, repo.pathFor(id, meta.vocalsFile), track, lrc.lines, pins: pins, readings: readings,
          pitchModelPath: pitchModelPath, onProgress: onProgress, isCancelled: isCancelled,
        );
  if (isCancelled?.call() ?? false) throw const SeparationCancelled();
  if (hubertFaPath != null && pins.entries.any((pin) =>
      reference.lines[pin.key.$1].tokens[pin.key.$2].pinned != pin.value)) {
    throw ImportException('新歌词的对齐结果与手动位置冲突，已保留原音高图');
  }
  if (hubertFaPath == null) {
    for (final MapEntry(key: (k, i), :value) in readings.entries) {
      reference.lines[k].tokens[i].pinyinOverride = value;
    }
  } else {
    meta.modelInfo['alignment'] = 'HuBERTFA';
    meta.modelInfo.remove('alignmentModelError');
  }
  final moved = old == null ? null : matchLines(old.lines, reference.lines);
  if (old != null) reference.applyCorrectionsFrom(old, moved);
  onSaving?.call();
  if (measured != null) {
    await repo.savePitchTrack(id, measured);
    meta.modelInfo[ImportPipeline.pitchInfo] = PitchModel.name;
    meta.modelInfo.remove('pitchModelError');
  }
  await repo.saveReference(id, reference);
  if (old != null) await repo.remapHistory(id, old, moved!);
  meta.lyrics = lyrics;
  await repo.save(meta);
}
