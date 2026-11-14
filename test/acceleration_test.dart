// The vocal model with Core ML: the import's guard (check against the CPU,
// fall back to the CPU whatever goes wrong, crash marker) and the policy
// that decides per device (VocalAcceleration). Fake models; no Core ML here.
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/separation/mdx_separator.dart';
import 'package:yintrace/src/separation/model_config.dart';
import 'package:yintrace/src/separation/tensor_model.dart';
import 'package:yintrace/src/ui/settings_page.dart';
import 'package:yintrace/src/ui/theme.dart';

import 'support/synth_voice.dart';

const sr = 44100;

class FakeModel implements TensorModel {
  FakeModel(this.output);
  final Float32List Function(Float32List x, int run) output;
  int runs = 0;
  bool closed = false;
  double maxInput = 0;

  @override
  Future<Float32List> run(Float32List x, List<int> shape) async {
    for (final v in x) {
      if (v.abs() > maxInput) maxInput = v.abs();
    }
    return output(x, runs++);
  }

  @override
  Future<void> close() async => closed = true;
}

Float32List same(Float32List x, int _) => Float32List.fromList(x);

/// Loads fake models: the vocal model returns its input (on the CPU, and
/// with Core ML unless [coreML] says otherwise), the karaoke mask is 0.
class Loader {
  Loader({this.coreML = same, this.loadFails = false, this.onCoreMLLoad});
  final Float32List Function(Float32List x, int run) coreML;
  final bool loadFails;
  final void Function()? onCoreMLLoad;
  final calls = <String>[];
  final vocalCpu = <FakeModel>[];
  FakeModel? vocalCoreML;

  Future<TensorModel> call(
    String path, {
    required String inputName,
    required String outputName,
    Map<String, String>? coreML,
  }) async {
    final vocal = path.endsWith('mdx.onnx');
    calls.add('${vocal ? 'mdx' : 'vr'}${coreML == null ? '' : ' coreml'}');
    if (!vocal) return FakeModel((x, _) => Float32List(x.length));
    if (coreML != null) {
      onCoreMLLoad?.call();
      if (loadFails) throw StateError('Core ML is not available');
      return vocalCoreML = FakeModel(this.coreML);
    }
    final m = FakeModel(same);
    vocalCpu.add(m);
    return m;
  }
}

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('yt_accel'));
  tearDown(() => tmp.deleteSync(recursive: true));

  /// Imports a synthesized song; the voice starts at [voiceAt] seconds and
  /// everything before is digital silence.
  Future<SongMeta> importWith(
    Loader loader, {
    bool coreML = true,
    bool verify = true,
    String? marker,
    double voiceAt = 1.1,
    bool Function()? isCancelled,
  }) async {
    final syls = [
      for (var i = 0; i < 6; i++) Syl(voiceAt + i * 0.4, voiceAt + i * 0.4 + 0.33, <double>[60, 62, 64, 65, 67, 67][i]),
      for (var i = 0; i < 4; i++) Syl(voiceAt + 4 + i * 0.5, voiceAt + 4 + i * 0.5 + 0.42, <double>[69, 67, 65, 64][i]),
    ];
    final seconds = voiceAt + 7;
    final voice = synthVoice(syls, seconds)..fillRange(0, ((voiceAt - 0.1) * sr).round(), 0);
    final stereo = Float32List(voice.length * 2);
    for (var i = 0; i < voice.length; i++) {
      stereo[2 * i] = voice[i];
      stereo[2 * i + 1] = voice[i];
    }
    writeWavFile('${tmp.path}/song.wav', stereo, 2, sr);
    String at(double t) => '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toStringAsFixed(2).padLeft(5, '0')}';
    // Original example lines written for this project.
    final lyrics = '[${at(voiceAt - 0.1)}]纸鸢飞过山岗\n[${at(voiceAt + 3.9)}]灯火渐明\n';
    final pipeline = ImportPipeline(
      audio: const WavAudioBackend(),
      repository: SongRepository(Directory('${tmp.path}/songs')),
      loadModel: loader.call,
    );
    return pipeline.run(
      ImportRequest(
        audioPath: '${tmp.path}/song.wav',
        lyrics: lyrics,
        title: '测试',
        mdxModelPath: '${tmp.path}/mdx.onnx',
        vrModelPath: '${tmp.path}/vr.onnx',
        keepOriginal: false,
        mdxCoreML: coreML ? vocalCoreMLOptions : null,
        coreMLMarker: marker,
        verifyCoreML: verify,
      ),
      isCancelled: isCancelled,
    );
  }

  group('import with Core ML', () {
    test('agreeing with the CPU: Core ML separates the song, checked once', () async {
      final marker = '${tmp.path}/coreml-trial';
      var markerWhileLoading = false;
      final loader = Loader(onCoreMLLoad: () => markerWhileLoading = File(marker).existsSync());
      final meta = await importWith(loader, marker: marker);
      expect(loader.calls, ['mdx coreml', 'mdx', 'vr'], reason: 'one CPU model only for the check');
      expect(markerWhileLoading, isTrue);
      expect(File(marker).existsSync(), isFalse);
      expect(meta.modelInfo['mdxRuntime'], 'Core ML');
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'checked 300.0 dB');
      final chunks = MdxSeparator(loader.vocalCoreML!, MdxConfig.vocFt).chunkCount((8.1 * sr).round());
      expect(loader.vocalCoreML!.runs, chunks);
      expect(loader.vocalCpu.single.runs, 1);
      expect(loader.vocalCpu.single.closed, isTrue);
      expect(loader.vocalCoreML!.closed, isTrue);
      expect(double.parse(meta.modelInfo['mdxRunSeconds']!), greaterThan(0));
      expect(double.parse(meta.modelInfo['vrRunSeconds']!), greaterThan(0));
      expect(meta.modelInfo['vrWindow'], '512');
    });

    test('once checked, the CPU model is not loaded for the vocals', () async {
      final loader = Loader();
      final meta = await importWith(loader, verify: false);
      expect(loader.calls, ['mdx coreml', 'vr']);
      expect(meta.modelInfo['mdxRuntime'], 'Core ML');
      expect(meta.modelInfo.containsKey(ImportPipeline.coreMLInfo), isFalse);
    });

    test('a Core ML session that cannot be created: the CPU, and why', () async {
      final marker = '${tmp.path}/coreml-trial';
      final loader = Loader(loadFails: true);
      final meta = await importWith(loader, marker: marker);
      expect(loader.calls, ['mdx coreml', 'mdx', 'vr']);
      expect(meta.modelInfo['mdxRuntime'], 'CPU');
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'error: Bad state: Core ML is not available');
      expect(File(marker).existsSync(), isFalse);
    });

    test('disagreeing with the CPU: the song is finished on the CPU', () async {
      final loader = Loader(coreML: (x, _) => Float32List.fromList([for (final v in x) v * 0.5]));
      final meta = await importWith(loader);
      expect(meta.modelInfo['mdxRuntime'], 'CPU');
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'mismatch 6.0 dB');
      expect(loader.vocalCoreML!.runs, 1);
      expect(loader.vocalCoreML!.closed, isTrue);
      final chunks = MdxSeparator(loader.vocalCoreML!, MdxConfig.vocFt).chunkCount((8.1 * sr).round());
      // The check's CPU result is used for the first chunk, the CPU model
      // loaded for the fallback does the rest.
      expect(loader.vocalCpu.map((m) => m.runs), [1, chunks - 1]);
    });

    test('values that are not finite: the CPU', () async {
      final loader = Loader(coreML: (x, _) => Float32List(x.length)..[7] = double.nan);
      final meta = await importWith(loader, verify: false);
      expect(meta.modelInfo['mdxRuntime'], 'CPU');
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'invalid output');
    });

    test('a run that fails half way: the rest on the CPU', () async {
      final loader = Loader(coreML: (x, run) => run == 2 ? throw StateError('GPU lost') : Float32List.fromList(x));
      final meta = await importWith(loader);
      expect(meta.modelInfo['mdxRuntime'], 'CPU');
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'error: Bad state: GPU lost');
      expect(loader.vocalCoreML!.runs, 3);
    });

    test('digital silence is not used for the check', () async {
      final loader = Loader();
      final meta = await importWith(loader, voiceAt: 4.2);
      expect(meta.modelInfo[ImportPipeline.coreMLInfo], 'checked 300.0 dB');
      expect(loader.vocalCpu.single.maxInput, greaterThan(0), reason: 'compared on a chunk with sound');
    });

    test('an import stopped before the first chunk leaves no crash marker', () async {
      final marker = '${tmp.path}/coreml-trial';
      var loaded = false;
      final loader = Loader(onCoreMLLoad: () => loaded = true);
      await expectLater(
        importWith(loader, marker: marker, isCancelled: () => loaded),
        throwsA(isA<SeparationCancelled>()),
      );
      expect(File(marker).existsSync(), isFalse);
    });

    test('the request carries the Core ML choice to the import worker', () {
      const r = ImportRequest(
        audioPath: 'a',
        lyrics: 'l',
        title: 't',
        mdxCoreML: vocalCoreMLOptions,
        coreMLMarker: 'm',
        verifyCoreML: true,
        speed: {'mdx.coreml': 0.4, 'vr.512': 1.3},
      );
      final back = ImportRequest.fromMap(r.toMap());
      expect(back.mdxCoreML, vocalCoreMLOptions);
      expect(back.coreMLMarker, 'm');
      expect(back.verifyCoreML, isTrue);
      expect(back.speed, {'mdx.coreml': 0.4, 'vr.512': 1.3});
      expect(ImportRequest.fromMap(const ImportRequest(audioPath: 'a', lyrics: 'l', title: 't').toMap()).speed, isEmpty);
    });
  });

  group('VocalAcceleration', () {
    late File model;
    setUp(() => model = File('${tmp.path}/vocals.onnx')..writeAsStringSync('weights'));

    test('first import on a device: Core ML on the GPU, compared with the CPU', () async {
      final a = await VocalAcceleration.load(tmp, supported: true);
      final first = await a.beforeImport(model.path);
      expect(first.coreML!['ModelFormat'], 'MLProgram');
      expect(first.coreML!['MLComputeUnits'], 'CPUAndGPU');
      expect(Directory(first.coreML!['ModelCacheDirectory']!).existsSync(), isTrue);
      expect(first.marker, '${tmp.path}/coreml-trial');
      expect(first.verify, isTrue);
      expect(a.status, '下次导入时先和 CPU 对比一次，结果一致才用');

      await a.afterImport({
        'mdxRuntime': 'Core ML',
        ImportPipeline.coreMLInfo: 'checked 109.0 dB',
        'mdxRunSeconds': '0.380',
        'vrWindow': '512',
        'vrRunSeconds': '1.400',
      });
      final again = await (await VocalAcceleration.load(tmp, supported: true)).beforeImport(model.path);
      expect(again.verify, isFalse, reason: 'checked for this app and system version');
      expect(again.speed, {'mdx.coreml': 0.38, 'vr.512': 1.4});
      expect(a.status, '在这台设备上和 CPU 对比过，结果一致');
    });

    test('measured speeds are kept per runtime and window, averaged', () async {
      final a = VocalAcceleration(tmp, supported: true);
      await a.afterImport({'mdxRuntime': 'CPU', 'mdxRunSeconds': '0.900', 'vrWindow': '320', 'vrRunSeconds': '0.800'});
      await a.afterImport({'mdxRuntime': 'CPU', 'mdxRunSeconds': '0.800', 'vrWindow': '512', 'vrRunSeconds': 'x'});
      await a.afterImport({'mdxRuntime': 'Core ML', 'mdxRunSeconds': '0.400'});
      expect(a.speed, {'mdx.cpu': closeTo(0.85, 1e-9), 'vr.320': 0.8, 'mdx.coreml': 0.4});
      expect(a.status, '下次导入时先和 CPU 对比一次，结果一致才用');
      await a.afterImport({'mdxRuntime': 'Core ML', ImportPipeline.coreMLInfo: 'checked 109.0 dB'});
      expect(a.status, '在这台设备上和 CPU 对比过，结果一致，人声分离快 2.1 倍');
    });

    test('the app was closed while Core ML started: off, until switched on again', () async {
      final a = VocalAcceleration(tmp, supported: true);
      final first = await a.beforeImport(model.path);
      File(first.marker!).writeAsStringSync('started'); // the import never finished its first chunk
      final next = await a.beforeImport(model.path);
      expect(next.coreML, isNull);
      expect(a.active, isFalse);
      expect(a.disabledReason, VocalAcceleration.crashedReason);
      expect(a.status, startsWith('已自动关闭：上次用它分离人声时 App 被系统关闭了'));
      expect(File(first.marker!).existsSync(), isFalse);
      await a.setEnabled(true);
      final retry = await a.beforeImport(model.path);
      expect(retry.coreML, isNotNull);
      expect(retry.verify, isTrue);
    });

    test('a disagreeing or failing check turns Core ML off', () async {
      final a = VocalAcceleration(tmp, supported: true);
      await a.afterImport({'mdxRuntime': 'CPU', ImportPipeline.coreMLInfo: 'mismatch 12.0 dB'});
      expect(a.active, isFalse);
      expect(a.status, startsWith('已自动关闭：它算出的结果和 CPU 不一致'));
      await a.setEnabled(true);
      await a.afterImport({'mdxRuntime': 'CPU', ImportPipeline.coreMLInfo: 'error: no GPU'});
      expect(a.disabledReason, '它出错了（no GPU）');
      expect((await a.beforeImport(model.path)).coreML, isNull);
    });

    test('switched off by the user, or no Core ML on this platform: the CPU', () async {
      final a = VocalAcceleration(tmp, supported: true);
      await a.setEnabled(false);
      expect((await a.beforeImport(model.path)).coreML, isNull);
      expect(a.status, '关闭时人声分离只用 CPU，会慢一些');
      expect((await VocalAcceleration(tmp, supported: false).beforeImport(model.path)).coreML, isNull);
      expect((await VocalAcceleration.unavailable().beforeImport(model.path)).coreML, isNull);
    });

    test('a changed model gets a new compiled-model cache', () async {
      final a = VocalAcceleration(tmp, supported: true);
      final before = (await a.beforeImport(model.path)).coreML!['ModelCacheDirectory']!;
      expect((await a.beforeImport(model.path)).coreML!['ModelCacheDirectory'], before);
      model.writeAsStringSync('other weights, longer');
      final after = (await a.beforeImport(model.path)).coreML!['ModelCacheDirectory']!;
      expect(after, isNot(before));
      expect(Directory(before).existsSync(), isFalse);
      expect(Directory(after).existsSync(), isTrue);
    });
  });

  testWidgets('settings: the GPU switch shows what the checks found', (tester) async {
    final a = VocalAcceleration(null, supported: true);
    final services = AppServices(
      settings: AppSettings(null),
      songs: SongRepository(tmp),
      models: ModelManager(dir: tmp, loadRecipe: (_) => throw StateError('unused')),
      acceleration: a,
    );
    await tester.binding.setSurfaceSize(const Size(400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const SettingsPage()),
      ),
    );
    expect(find.text('用 GPU 加速人声分离'), findsOneWidget);
    expect(find.text('下次导入时先和 CPU 对比一次，结果一致才用'), findsOneWidget);
    await tester.tap(find.text('用 GPU 加速人声分离'));
    await tester.pump();
    expect(a.userEnabled, isFalse);
    expect(find.text('关闭时人声分离只用 CPU，会慢一些'), findsOneWidget);

    // Platforms without Core ML show no switch.
    await tester.pumpWidget(
      AppScope(
        services: AppServices(settings: AppSettings(null), songs: services.songs, models: services.models),
        child: MaterialApp(theme: buildTheme(Brightness.light), home: const SettingsPage()),
      ),
    );
    expect(find.text('用 GPU 加速人声分离'), findsNothing);
  });
}
