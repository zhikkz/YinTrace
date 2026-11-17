import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:yintrace_audio/yintrace_audio.dart';

import '../dsp/swift_f0.dart';
import '../import/vocal_acceleration.dart';
import '../library/song_repository.dart';
import '../models/model_manager.dart';
import '../models/model_catalog.dart';
import '../models/model_recipe.dart';
import '../models/pitch_model.dart';
import '../practice/live_pitch.dart';
import '../separation/onnx_model.dart';
import '../separation/tensor_model.dart';
import 'settings.dart';
import 'test_build.dart';

/// Loads the pitch model at [path] for live use.
typedef PitchModelLoader = Future<TensorModel> Function(String path);

/// Long-lived app objects.
class AppServices {
  AppServices({
    required this.settings,
    required this.songs,
    required this.models,
    VocalAcceleration? acceleration,
    this.pitchModelPath,
    this.loadPitchModel = loadLivePitchModel,
  }) : acceleration = acceleration ?? VocalAcceleration.unavailable();

  final AppSettings settings;
  final SongRepository songs;
  final ModelManager models;

  /// Whether the vocal model runs with Core ML here, and how fast this
  /// device separated songs before.
  final VocalAcceleration acceleration;

  /// The pitch model on disk ([PitchModel]), or null when it could not be
  /// put there (and in tests): then YIN measures the pitch.
  final String? pitchModelPath;
  final PitchModelLoader loadPitchModel;

  /// The pitch model to measure with: none when there is none, or when a
  /// test build is set to compare with YIN.
  String? get activePitchModel => isTestBuild && settings.yinPitch ? null : pitchModelPath;

  /// Why the pitch model could not be loaded the last time, if it could not.
  String? pitchModelFailure;

  /// Measures the singer's pitch for practice and free practice: with the
  /// pitch model, or with YIN when there is no model or it cannot be loaded.
  Future<LivePitchSource> livePitch({required int sampleRate, required LivePitchOptions options}) async {
    final path = activePitchModel;
    if (path != null) {
      try {
        final model = await loadPitchModel(path);
        pitchModelFailure = null;
        return ModelPitchTracker(sampleRate: sampleRate, model: SwiftF0(model), options: options);
      } catch (e) {
        pitchModelFailure = '$e'.split('\n').first;
      }
    }
    return LivePitchTracker(sampleRate: sampleRate, options: options);
  }

  static Future<AppServices> init() async {
    final support = await getApplicationSupportDirectory();
    final songs = SongRepository(Directory('${support.path}/songs'));
    await songs.root.create(recursive: true);
    void excludeFromBackup(String path) {
      try {
        NativeAudio.excludeFromBackup(path);
      } catch (_) {}
    }

    final models = ModelManager(
      dir: Directory('${support.path}/models'),
      loadRecipe: loadBundledRecipe,
      // The models can be downloaded again: keep them out of iCloud backups.
      excludeFromBackup: excludeFromBackup,
    );
    final settings = await AppSettings.load(File('${support.path}/settings.json'));
    final acceleration = await VocalAcceleration.load(support);
    String? pitchModel;
    try {
      // The bundled pitch model is copied next to the downloaded ones.
      pitchModel = await PitchModel.install(models.dir, rootBundle.load);
      excludeFromBackup(models.dir.path);
    } catch (_) {
      // YIN measures the pitch instead.
    }
    return AppServices(
      settings: settings,
      songs: songs,
      models: models,
      acceleration: acceleration,
      pitchModelPath: pitchModel,
    );
  }
}

/// The pitch model for live use: one thread, which sleeps between the runs
/// (about 30 a second, each a few milliseconds).
Future<TensorModel> loadLivePitchModel(String path) => OnnxTensorModel.load(
      path,
      inputName: PitchModel.inputName,
      outputName: PitchModel.outputName,
      threads: 1,
      sessionConfigs: const {'session.intra_op.allow_spinning': '0'},
    );

/// The recipe bundled with the app that assembles the karaoke model.
Future<ModelRecipe> loadBundledRecipe(ModelSpec spec) async {
  final name = spec.id == vocalModel.id ? 'mdx_graph' : 'karaoke_graph';
  final json = await rootBundle.loadString('assets/models/$name.json');
  final graph = await rootBundle.load('assets/models/$name.bin');
  return ModelRecipe.parse(json, graph.buffer.asUint8List(graph.offsetInBytes, graph.lengthInBytes));
}

/// Makes [AppServices] available to the widget tree.
class AppScope extends InheritedWidget {
  const AppScope({super.key, required this.services, required super.child});

  final AppServices services;

  static AppServices of(BuildContext context) {
    final scope = context.dependOnInheritedWidgetOfExactType<AppScope>();
    assert(scope != null, 'AppScope missing');
    return scope!.services;
  }

  @override
  bool updateShouldNotify(AppScope oldWidget) => services != oldWidget.services;
}
