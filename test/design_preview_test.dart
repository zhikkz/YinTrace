// Renders every screen with a real song for design review. Opt-in:
//
//   DESIGN_SONG_DIR=<dir with reference.json, pitch.bin, vocal.wav>
//   DESIGN_LYRICS=<lrc file>  YINTRACE_AUDIO_LIB=<host lib>  SCREENSHOT_DIR=<out>
//   flutter test test/design_preview_test.dart
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/ui/import_page.dart';
import 'package:yintrace/src/ui/library_page.dart';
import 'package:yintrace/src/ui/practice_page.dart';
import 'package:yintrace/src/ui/settings_page.dart';
import 'package:yintrace/src/ui/song_page.dart';
import 'package:yintrace/src/ui/theme.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/synth_voice.dart';
import 'ui_test.dart' show loadFonts, screenshot, settleIo, shotKey;

Widget host(AppServices services, Widget home, {Brightness brightness = Brightness.light}) => AppScope(
  services: services,
  child: RepaintBoundary(
    key: shotKey,
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: buildTheme(brightness), home: home),
  ),
);

void main() {
  final dir = Platform.environment['DESIGN_SONG_DIR'];
  final lyricsPath = Platform.environment['DESIGN_LYRICS'];
  final skip = dir == null || lyricsPath == null || Platform.environment['YINTRACE_AUDIO_LIB'] == null;
  late AppServices services;
  late SongMeta song;
  late SongReference ref;
  late Directory tmp;

  setUpAll(() async {
    if (skip) return;
    await loadFonts();
    tmp = Directory.systemTemp.createTempSync('yt_design');
    final repo = SongRepository(Directory('${tmp.path}/songs'));
    services = AppServices(
      settings: AppSettings(null),
      songs: repo,
      models: ModelManager(
        dir: Directory('${tmp.path}/models'),
        loadRecipe: (_) => throw StateError('unused'),
      ),
    );
    final id = repo.newSongId();
    File('$dir/reference.json').copySync(repo.pathFor(id, SongRepository.referenceFile));
    File('$dir/pitch.bin').copySync(repo.pathFor(id, SongRepository.pitchFile));
    File('$dir/vocal.wav').copySync(repo.pathFor(id, 'vocals.wav'));
    ref = SongReference.fromJson(
      jsonDecode(File('$dir/reference.json').readAsStringSync()) as Map<String, dynamic>,
    );
    song = SongMeta(
      id: id,
      title: Platform.environment['DESIGN_TITLE'] ?? '示例歌曲',
      artist: '黄霄雲',
      createdAt: DateTime(2026, 11, 13),
      duration: ref.duration,
      lyrics: File(lyricsPath).readAsStringSync(),
      vocalsFile: 'vocals.wav',
    );
    await repo.save(song);
    await repo.addPractice(
      id,
      PracticeRecord(
        at: DateTime.now(),
        score: 78,
        lineScores: {for (var i = 0; i < ref.lines.length; i++) i: 60 + (i * 37 % 38).toDouble()},
      ),
    );
    song = await repo.load(id);
    // Two more (fake) songs so the library has some variety.
    for (final t in [('平凡之路', '朴树'), ('起风了', '买辣椒也用券')]) {
      final other = repo.newSongId();
      File('$dir/reference.json').copySync(repo.pathFor(other, SongRepository.referenceFile));
      await repo.save(
        SongMeta(
          id: other,
          title: t.$1,
          artist: t.$2,
          createdAt: DateTime(2026, 11, 1),
          duration: 241,
          lyrics: '',
          vocalsFile: 'vocals.wav',
        ),
      );
    }
  });

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(393 * 3, 852 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  for (final b in Brightness.values) {
    final suffix = b == Brightness.dark ? '_dark' : '';
    testWidgets('library $b', (tester) async {
      phone(tester);
      await tester.pumpWidget(host(services, const LibraryPage(), brightness: b));
      await settleIo(tester, rounds: 30);
      await screenshot(tester, 'd1_library$suffix');
    }, skip: skip);

    testWidgets('song $b', (tester) async {
      phone(tester);
      await tester.pumpWidget(host(services, SongPage(songId: song.id), brightness: b));
      await settleIo(tester, rounds: 40);
      await screenshot(tester, 'd2_song$suffix');
    }, skip: skip);

    testWidgets('practice $b', (tester) async {
      phone(tester);
      final contour = await tester.runAsync(() => services.songs.loadPitchTrack(song.id));
      // A singer who follows the reference, sharp on some characters and
      // flat on others.
      final syls = <Syl>[];
      final rng = math.Random(5);
      for (final line in ref.lines) {
        for (final tok in line.tokens) {
          var dev = (rng.nextDouble() - 0.5) * 0.3;
          if (tok.text == '这') dev = 0.8;
          if (tok.text == '失' || tok.text == '联') dev = -0.7;
          for (final n in tok.notes) {
            syls.add(Syl(n.start + 0.03, n.end, n.midi + dev, unvoicedOnset: false));
          }
        }
      }
      final singer = synthVoice(syls, 80, seed: 3);
      late PracticeSession session;
      await tester.pumpWidget(
        host(
          services,
          PracticePage(
            meta: song,
            reference: ref,
            contour: contour,
            sessionFactory: (_) => session = PracticeSession(
              meta: song,
              reference: ref,
              contour: contour,
              repository: services.songs,
              settings: services.settings,
              engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
            ),
          ),
          brightness: b,
        ),
      );
      await settleIo(tester, rounds: 40);
      session.seek(67.5);
      session.play();
      final engine = session.engine!;
      while (engine.positionSeconds < 72.9) {
        final pos = engine.positionFrame;
        final input = Float32List(512);
        for (var i = 0; i < 512 && pos + i < singer.length; i++) {
          input[i] = singer[pos + i];
        }
        engine.render(512, input: input);
        await tester.pump(const Duration(milliseconds: 11));
      }
      await screenshot(tester, 'd3_practice$suffix');
      while (engine.positionSeconds < 75.6) {
        final pos = engine.positionFrame;
        final input = Float32List(512);
        for (var i = 0; i < 512 && pos + i < singer.length; i++) {
          input[i] = singer[pos + i];
        }
        engine.render(512, input: input);
        await tester.pump(const Duration(milliseconds: 11));
      }
      await tester.tap(find.byTooltip('查看评分'));
      await settleIo(tester, rounds: 40);
      await tester.pump(const Duration(seconds: 1));
      await screenshot(tester, 'd4_results$suffix');
      await tester.pumpWidget(const SizedBox());
    }, skip: skip);

    testWidgets('import $b', (tester) async {
      phone(tester);
      await tester.pumpWidget(host(services, const ImportPage(), brightness: b));
      await tester.pump();
      await tester.enterText(find.byType(TextField).last, File(lyricsPath!).readAsStringSync());
      await tester.pump(const Duration(milliseconds: 300));
      await screenshot(tester, 'd5_import$suffix');
    }, skip: skip);

    testWidgets('settings $b', (tester) async {
      phone(tester);
      await tester.pumpWidget(host(services, const SettingsPage(), brightness: b));
      await tester.pump();
      await screenshot(tester, 'd6_settings$suffix');
    }, skip: skip);
  }
}
