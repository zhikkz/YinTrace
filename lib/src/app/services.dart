import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:yintrace_audio/yintrace_audio.dart';

import '../import/import_queue.dart';
import '../import/vocal_acceleration.dart';
import '../library/song_repository.dart';
import '../models/model_manager.dart';
import '../models/model_catalog.dart';
import '../models/model_recipe.dart';
import '../models/pitch_model.dart';
import 'pitch_corrections.dart';
import 'settings.dart';
import 'test_build.dart';

/// Long-lived app objects.
class AppServices {
  AppServices({
    required this.settings,
    required this.songs,
    required this.models,
    VocalAcceleration? acceleration,
    ImportQueue? importQueue,
    this.pitchModelPath,
  }) : acceleration = acceleration ?? VocalAcceleration.unavailable() {
    this.importQueue = importQueue ?? ImportQueue(songs.root.path, this.acceleration);
  }

  final AppSettings settings;
  final SongRepository songs;
  final ModelManager models;
  late final ImportQueue importQueue;
  final pitchCorrections = PitchCorrections();

  /// Whether the vocal model runs with Core ML here, and how fast this
  /// device separated songs before.
  final VocalAcceleration acceleration;

  /// The pitch model on disk ([PitchModel]) that measures the original
  /// singer when a song is imported, or null when it could not be put there
  /// (and in tests): then YIN does. The singer's own pitch, live, is always
  /// measured with YIN.
  final String? pitchModelPath;

  /// The pitch model imports measure with: none when there is none, or when
  /// a test build is set to compare with YIN.
  String? get activePitchModel => isTestBuild && settings.yinPitch ? null : pitchModelPath;

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
      specs: [...separationModels, hubertFaModel],
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
      // Imports measure the pitch with YIN instead.
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
