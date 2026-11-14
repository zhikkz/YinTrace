import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import 'package:yintrace_audio/yintrace_audio.dart';

import '../library/song_repository.dart';
import '../models/model_manager.dart';
import '../models/model_catalog.dart';
import '../models/model_recipe.dart';
import 'settings.dart';

/// Long-lived app objects.
class AppServices {
  AppServices({required this.settings, required this.songs, required this.models});

  final AppSettings settings;
  final SongRepository songs;
  final ModelManager models;

  static Future<AppServices> init() async {
    final support = await getApplicationSupportDirectory();
    final songs = SongRepository(Directory('${support.path}/songs'));
    await songs.root.create(recursive: true);
    final models = ModelManager(
      dir: Directory('${support.path}/models'),
      loadRecipe: loadBundledRecipe,
      // The models can be downloaded again: keep them out of iCloud backups.
      excludeFromBackup: (path) {
        try {
          NativeAudio.excludeFromBackup(path);
        } catch (_) {}
      },
    );
    final settings = await AppSettings.load(File('${support.path}/settings.json'));
    return AppServices(settings: settings, songs: songs, models: models);
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
