import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:path_provider/path_provider.dart';

import '../library/song_repository.dart';
import 'model_store.dart';
import 'settings.dart';

/// Long-lived app objects.
class AppServices {
  AppServices({required this.settings, required this.songs, required this.models});

  final AppSettings settings;
  final SongRepository songs;
  final ModelStore models;

  static Future<AppServices> init() async {
    final docs = await getApplicationDocumentsDirectory();
    final support = await getApplicationSupportDirectory();
    final songs = SongRepository(Directory('${support.path}/songs'));
    await songs.root.create(recursive: true);
    final models = ModelStore(Directory('${docs.path}/models'));
    await models.dir.create(recursive: true);
    await models.installBundled(rootBundle);
    final settings = await AppSettings.load(File('${support.path}/settings.json'));
    return AppServices(settings: settings, songs: songs, models: models);
  }
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
