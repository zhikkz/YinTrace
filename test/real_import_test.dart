// Opt-in full-song import, using the real models and the production pipeline.
// Audio/lyrics are external inputs and must never be added to the repository.
// MODELS_DIR=... REAL_IMPORT_AUDIO=... REAL_IMPORT_LYRICS=... PYTHON=...
// YINTRACE_AUDIO_LIB=... flutter test test/real_import_test.dart
// REAL_IMPORT_OUT optionally keeps the resulting local song for inspection.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/models/model_recipe.dart';

import 'support/python_ort_model.dart';

void main() {
  final env = Platform.environment;
  final models = env['MODELS_DIR'];
  final audioPath = env['REAL_IMPORT_AUDIO'];
  final lyricsPath = env['REAL_IMPORT_LYRICS'];
  test(
    'real full-song ImportPipeline produces a finite, ordered per-word pitch chart',
    () async {
      final tmp = Directory.systemTemp.createTempSync('yt_real_import');
      final output = env['REAL_IMPORT_OUT'];
      final repo = SongRepository(Directory(output ?? '${tmp.path}/songs'));
      final loaded = <PythonOrtModel>[];
      try {
        final paths = <String>[];
        for (final pair in [(vocalModel, 'mdx_graph'), (karaokeModel, 'karaoke_graph')]) {
          final recipe = ModelRecipe.parse(
            File('assets/models/${pair.$2}.json').readAsStringSync(),
            File('assets/models/${pair.$2}.bin').readAsBytesSync(),
          );
          final path = '${tmp.path}/${pair.$1.installedName}';
          expect(recipe.assembleSync('$models/${pair.$1.fileName}', path), recipe.outputSha256);
          paths.add(path);
        }
        final lyrics = File(lyricsPath!).readAsStringSync();
        final parsed = parseLrc(lyrics);
        final watch = Stopwatch()..start();
        var lastPercent = -1;
        final meta =
            await ImportPipeline(
              audio: const NativeAudioBackend(),
              repository: repo,
              loadModel: (path, {required inputName, required outputName, coreML}) async {
                final model = await PythonOrtModel.start(path, python: env['PYTHON'] ?? 'python3');
                loaded.add(model);
                return model;
              },
            ).run(
              ImportRequest(
                audioPath: audioPath!,
                lyrics: lyrics,
                title: '完整导入验证',
                mdxModelPath: paths[0],
                vrModelPath: paths[1],
                keepOriginal: false,
              ),
              onProgress: (p) {
                final percent = (p.overall * 100).floor();
                if (percent != lastPercent) {
                  lastPercent = percent;
                  // ignore: avoid_print
                  print('import $percent% ${p.stage.label} (${watch.elapsed.inSeconds} s)');
                }
              },
            );
        final reference = await repo.loadReference(meta.id);
        final track = await repo.loadPitchTrack(meta.id);
        expect(reference.lines.length, parsed.lines.length);
        expect(track.duration, closeTo(meta.duration, 0.1));
        expect(reference.tokens.map((t) => t.text), parsed.lines.expand((l) => l.tokens).map((t) => t.text));
        var withPitch = 0;
        for (final line in reference.lines) {
          var previous = 0.0;
          for (final token in line.tokens) {
            expect(token.start.isFinite && token.end.isFinite, isTrue);
            expect(token.start, greaterThanOrEqualTo(previous));
            expect(token.end, greaterThanOrEqualTo(token.start));
            expect(token.end, lessThanOrEqualTo(meta.duration + 0.1));
            previous = token.start;
            if (token.notes.isNotEmpty) withPitch++;
            for (final note in token.notes) {
              expect(note.midi.isFinite, isTrue);
              expect(note.midi, inInclusiveRange(20, 120));
              expect(note.end, greaterThan(note.start));
            }
          }
        }
        expect(
          withPitch / reference.tokens.length,
          greaterThan(0.5),
          reason: 'most lyric units should have detected melody; inspect the input if this fails',
        );
        final expectedVocal = env['REAL_IMPORT_REFERENCE'];
        if (expectedVocal != null) {
          // Independently separated by UVR, then analysed using the same YIN
          // pipeline. This checks the reference pitch behind the stored chart.
          final pure = const WavAudioBackend().decode(expectedVocal, channels: 1);
          final expectedTrack = analyzePitch(pure.samples, 44100);
          final n = track.length < expectedTrack.length ? track.length : expectedTrack.length;
          var sameVoicing = 0, samePitch = 0, bothVoiced = 0;
          for (var i = 0; i < n; i++) {
            if (track.voiced(i) == expectedTrack.voiced(i)) sameVoicing++;
            if (track.voiced(i) && expectedTrack.voiced(i)) {
              bothVoiced++;
              if ((track.midi[i] - expectedTrack.midi[i]).abs() < 0.1) samePitch++;
            }
          }
          // Aligning ambiguous synthetic syllables is not a ground-truth
          // boundary test. Check the independent pitch curve plus the chart's
          // structural invariants above, without asserting arbitrary word times.
          expect(sameVoicing / n, greaterThan(0.98));
          expect(bothVoiced, greaterThan(0));
          expect(samePitch / bothVoiced, greaterThan(0.98));
        }
        expect(File(repo.pathFor(meta.id, meta.vocalsFile)).existsSync(), isTrue);
        expect(File(repo.pathFor(meta.id, meta.accompanimentFile!)).existsSync(), isTrue);
        // ignore: avoid_print
        print(
          'full import: ${meta.duration.toStringAsFixed(1)} s audio, '
          '${watch.elapsed.inSeconds} s elapsed, ${reference.tokens.length} lyric units; '
          'Dart peak RSS ${ProcessInfo.maxRss / 1e6} MB',
        );
      } finally {
        tmp.deleteSync(recursive: true);
      }
    },
    skip: models == null || audioPath == null || lyricsPath == null
        ? 'set MODELS_DIR, REAL_IMPORT_AUDIO and REAL_IMPORT_LYRICS to run'
        : false,
    timeout: const Timeout(Duration(hours: 2)),
  );
}
