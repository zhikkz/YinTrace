import 'dart:io';
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
    this.useCoreML = false,
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
  final bool useCoreML;
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
    'useCoreML': useCoreML,
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
    useCoreML: m['useCoreML'] as bool? ?? false,
    keepOriginal: m['keepOriginal'] as bool? ?? true,
  );
}

class ImportProgress {
  const ImportProgress(this.stage, this.stageFraction, this.overall);
  final ImportStage stage;
  final double stageFraction;
  final double overall;
}

typedef ModelLoader = Future<TensorModel> Function(
  String path, {
  required String inputName,
  required String outputName,
  bool useCoreML,
});

class ImportException implements Exception {
  ImportException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Turns an audio file + timed lyrics into a practice-ready song.
class ImportPipeline {
  ImportPipeline({required this.audio, required this.loadModel, required this.repository});

  final AudioBackend audio;
  final ModelLoader loadModel;
  final SongRepository repository;

  static const _weights = {
    ImportStage.decoding: 0.03,
    ImportStage.separatingVocals: 0.50,
    ImportStage.removingHarmony: 0.32,
    ImportStage.analyzingPitch: 0.07,
    ImportStage.aligning: 0.02,
    ImportStage.saving: 0.06,
  };

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
    final stages = <ImportStage>[
      ImportStage.decoding,
      if (separate) ImportStage.separatingVocals,
      if (separate && r.vrModelPath != null) ImportStage.removingHarmony,
      ImportStage.analyzingPitch,
      ImportStage.aligning,
      ImportStage.saving,
    ];
    final total = stages.fold<double>(0, (s, e) => s + _weights[e]!);
    void report(ImportStage stage, double f) {
      if (isCancelled?.call() ?? false) throw const SeparationCancelled();
      var before = 0.0;
      for (final s in stages) {
        if (s == stage) break;
        before += _weights[s]!;
      }
      onProgress?.call(ImportProgress(stage, f, (before + _weights[stage]! * f) / total));
    }

    final id = repository.newSongId();
    final dir = repository.dirFor(id);
    try {
      report(ImportStage.decoding, 0);
      var mix = audio.decode(r.audioPath, sampleRate: 44100, channels: 2).samples;
      final duration = mix.length / 2 / 44100;
      if (mix.length < 2 * 44100) throw ImportException('音频太短');
      report(ImportStage.decoding, 1);

      Float32List vocals; // stereo
      Float32List? accompaniment;
      final modelInfo = <String, String>{};
      if (separate) {
        const mdxCfg = MdxConfig.vocFt;
        final mdx = await loadModel(
          r.mdxModelPath!,
          inputName: mdxCfg.inputName,
          outputName: mdxCfg.outputName,
          useCoreML: r.useCoreML,
        );
        try {
          vocals = await MdxSeparator(
            mdx,
            mdxCfg,
          ).separate(mix, onProgress: (f) => report(ImportStage.separatingVocals, f));
        } finally {
          await mdx.close();
        }
        modelInfo['mdx'] = mdxCfg.name;
        if (r.vrModelPath != null) {
          const vrCfg = VrConfig.karaoke6Hp;
          final vr = await loadModel(
            r.vrModelPath!,
            inputName: vrCfg.inputName,
            outputName: vrCfg.outputName,
            useCoreML: r.useCoreML,
          );
          try {
            // The karaoke model's secondary stem is the lead vocal.
            vocals = await VrSeparator(vr, vrCfg).separate(
              vocals,
              stem: VrStem.secondary,
              onProgress: (f) => report(ImportStage.removingHarmony, f),
            );
            modelInfo['vr'] = vrCfg.name;
          } finally {
            await vr.close();
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
