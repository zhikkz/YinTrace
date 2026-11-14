import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import '../analysis/aligner.dart';
import '../analysis/lrc.dart';
import '../analysis/pitch_track.dart';
import '../audio/audio_backend.dart';
import '../library/song.dart';
import '../library/song_repository.dart';
import '../separation/mdx_separator.dart';
import '../separation/model_config.dart';
import '../separation/tensor_model.dart';
import '../separation/vr_separator.dart';

enum ImportStage {
  decoding('读取音频'),
  separatingVocals('分离人声'),
  removingHarmony('去掉和声'),
  analyzingPitch('测量音高'),
  aligning('把每个字对到音高上'),
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
    this.keepOriginal = true,
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
  final bool keepOriginal;

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
    keepOriginal: m['keepOriginal'] as bool? ?? true,
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

typedef ModelLoader = Future<TensorModel> Function(
  String path, {
  required String inputName,
  required String outputName,
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
      clock = _ImportClock({
        ImportStage.decoding: 0.003 * duration,
        if (separate) ImportStage.separatingVocals: mdx.chunkCount(frames).toDouble(),
        // One VR run against one MDX run on the same device: about 1.1 at
        // 512 frames and 0.8 at 320 (x86 desktop: 1.10 / 0.72 / 0.95 s,
        // ARM simulator: 4.66 / 3.73 / 4.81 s). It weighs the progress bar,
        // and the remaining-time estimate until VR's own speed is measured.
        if (harmony)
          ImportStage.removingHarmony:
              (vr.inferenceCount(frames) + 0.3 * vr.segmentCount(frames)) * (vrCfg.windowSize >= 512 ? 1.1 : 0.8),
        ImportStage.analyzingPitch: 0.02 * duration,
        ImportStage.aligning: 0.005 * duration,
        ImportStage.saving: 0.015 * duration,
      });
      report(ImportStage.decoding, 1);

      Float32List vocals; // stereo
      Float32List? accompaniment;
      final modelInfo = <String, String>{};
      if (separate) {
        final model = await loadModel(r.mdxModelPath!, inputName: mdxCfg.inputName, outputName: mdxCfg.outputName);
        try {
          vocals = await MdxSeparator(model, mdxCfg).separate(
            mix,
            onStep: (done, total) => report(ImportStage.separatingVocals, done / total, done: done, total: total),
          );
        } finally {
          await model.close();
        }
        modelInfo['mdx'] = mdxCfg.name;
        if (harmony) {
          // Keep only the MDX vocals while VR owns its large working set.
          // Re-decode the local source after closing VR to make accompaniment;
          // decoding twice costs far less memory than retaining a whole mix.
          mix = Float32List(0);
          final model = await loadModel(r.vrModelPath!, inputName: vrCfg.inputName, outputName: vrCfg.outputName);
          try {
            var done = 0;
            final runs = vr.inferenceCount(frames);
            // The karaoke model's secondary stem is the lead vocal.
            vocals = await VrSeparator(model, vrCfg).separate(
              vocals,
              stem: VrStem.secondary,
              onStep: (d, _) => done = d,
              onProgress: (f) => report(ImportStage.removingHarmony, f, done: done, total: runs),
            );
            modelInfo['vr'] = vrCfg.windowSize == 512 ? vrCfg.name : '${vrCfg.name} (window ${vrCfg.windowSize})';
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
      report(ImportStage.analyzingPitch, 0);
      final track = analyzePitch(mono, 44100, onProgress: (f) => report(ImportStage.analyzingPitch, f));
      report(ImportStage.aligning, 0);
      final reference = buildReference(track, lrc.lines);
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

/// Weighs the stages of an import by their work and estimates the time
/// left from how fast this device has actually been working.
///
/// Work is counted in units of about one MDX model run. The remaining time
/// uses the rate of the current stage once it has run for a while (its
/// first seconds include loading a model), else the rate of the stage
/// before it.
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
Future<void> realignSong(SongRepository repo, String id, String lyrics) async {
  final lrc = parseLrc(lyrics);
  if (lrc.lines.isEmpty) throw ImportException('没有解析到带时间的歌词');
  final track = await repo.loadPitchTrack(id);
  await repo.saveReference(id, buildReference(track, lrc.lines));
  final meta = await repo.load(id);
  meta.lyrics = lyrics;
  await repo.save(meta);
}
