// Widget tests for the main screens. The practice test runs the real
// native engine in offline mode (set YINTRACE_AUDIO_LIB, see
// packages/yintrace_audio/tool/run_dart_tests.sh) with a synthetic singer
// fed into the microphone input.
//
// Set SCREENSHOT_DIR to also write PNG screenshots.
import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/ui/about_page.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace/src/ui/import_page.dart';
import 'package:yintrace/src/ui/library_page.dart';
import 'package:yintrace/src/ui/settings_page.dart';
import 'package:yintrace/src/ui/practice_page.dart';
import 'package:yintrace/src/ui/song_page.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/synth_voice.dart';

const sr = 44100;
const lyrics = '[00:01.00]夜里的风慢慢吹过窗台\n[00:06.50]下雨了 记得带伞\n';
final shotKey = GlobalKey();

List<Syl> melody() {
  final out = <Syl>[];
  const p1 = <double>[62, 64, 65, 67, 65, 64, 62, 60, 62, 64];
  var t = 1.15;
  for (var i = 0; i < 10; i++) {
    final double d = i == 9 ? 0.8 : 0.3;
    out.add(Syl(t, t + d, p1[i]));
    t += d + 0.08;
  }
  const p2 = <double>[67, 69, 67, 72, 71, 69, 67];
  t = 6.6;
  for (var i = 0; i < 7; i++) {
    if (i == 3) t += 0.4;
    final double d = i == 6 ? 0.7 : 0.3;
    out.add(Syl(t, t + d, p2[i]));
    t += d + 0.08;
  }
  return out;
}

Future<void> loadFonts() async {
  Future<void> load(String family, String path) async {
    final f = File(path);
    if (!f.existsSync()) return;
    final loader = FontLoader(family)..addFont(Future.value(ByteData.sublistView(f.readAsBytesSync())));
    await loader.load();
  }

  final flutterRoot = Platform.environment['FLUTTER_ROOT'] ?? '/opt/sdk/flutter';
  await load('MaterialIcons', '$flutterRoot/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf');
  await load('Roboto', '/usr/share/fonts/truetype/wqy/wqy-zenhei.ttc');
}

Future<void> screenshot(WidgetTester tester, String name) async {
  final dir = Platform.environment['SCREENSHOT_DIR'];
  if (dir == null) return;
  final boundary = shotKey.currentContext!.findRenderObject()! as RenderRepaintBoundary;
  await tester.runAsync(() async {
    final image = await boundary.toImage(pixelRatio: 2);
    final bytes = await image.toByteData(format: ui.ImageByteFormat.png);
    Directory(dir).createSync(recursive: true);
    File('$dir/$name.png').writeAsBytesSync(bytes!.buffer.asUint8List());
  });
}

/// Lets real file I/O complete inside the fake-async test zone.
Future<void> settleIo(WidgetTester tester, {int rounds = 15}) async {
  for (var i = 0; i < rounds; i++) {
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
    await tester.pump(const Duration(milliseconds: 16));
  }
}

Widget host(AppServices services, Widget home) => AppScope(
      services: services,
      child: RepaintBoundary(
        key: shotKey,
        child: MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: YinTraceApp.theme(Brightness.light),
          home: home,
        ),
      ),
    );

void main() {
  late Directory tmp;
  late AppServices services;
  late SongMeta song;
  late Float32List singer;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    await loadFonts();
    tmp = Directory.systemTemp.createTempSync('yt_ui');
    final songs = SongRepository(Directory('${tmp.path}/songs'));
    services = AppServices(
      settings: AppSettings(null),
      songs: songs,
      models: ModelManager(
        dir: Directory('${tmp.path}/models'),
        loadRecipe: () => throw StateError('unused'),
      ),
    );
    // A "pure vocal" + accompaniment import (no models needed).
    final m = melody();
    final voice = synthVoice(m, 10);
    final acc = Float32List(voice.length * 2);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    writeWavFile('${tmp.path}/acc.wav', acc, 2, sr);
    song = await ImportPipeline(
      audio: const WavAudioBackend(),
      repository: songs,
      loadModel: (p, {required inputName, required outputName, useCoreML = false}) => throw StateError('unused'),
    ).run(ImportRequest(
      audioPath: '${tmp.path}/vocal.wav',
      accompanimentPath: '${tmp.path}/acc.wav',
      lyrics: lyrics,
      title: '夜航（示例）',
      artist: '演示',
      vocalsOnly: true,
    ));
    await songs.addPractice(song.id, PracticeRecord(at: DateTime.now(), score: 82, lineScores: {0: 88, 1: 71}));
    // The singer: right on most characters, flat on 3–4, sharp on line 2's
    // 4th character, skipping the 9th character.
    final sung = <Syl>[
      for (var i = 0; i < m.length; i++)
        if (i != 8)
          Syl(m[i].start + 0.02, m[i].end, m[i].midi + (i == 3 || i == 4 ? -0.7 : (i == 13 ? 0.9 : 0.05)))
    ];
    singer = synthVoice(sung, 10, seed: 9);
  });

  tearDownAll(() => tmp.deleteSync(recursive: true));

  void phone(WidgetTester tester) {
    tester.view.physicalSize = const Size(390 * 3, 844 * 3);
    tester.view.devicePixelRatio = 3;
    addTearDown(tester.view.reset);
  }

  testWidgets('library lists the imported song', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const LibraryPage()));
    await settleIo(tester);
    expect(find.text('夜航（示例）'), findsOneWidget);
    expect(find.text('82'), findsOneWidget);
    // The separation models are not installed: the library offers them.
    expect(find.textContaining('两个分离模型（194 MB）'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '下载'), findsOneWidget);
    await screenshot(tester, '1_library');
  });

  testWidgets('song page shows the per-character pitch map', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, SongPage(songId: song.id)));
    await settleIo(tester, rounds: 40);
    await screenshot(tester, '2_song');
    expect(find.text('夜里的风慢慢吹过窗台'), findsOneWidget);
    expect(find.text('下雨了 记得带伞'), findsOneWidget);
    expect(find.text('88'), findsOneWidget);
  });

  testWidgets('import page validates the timed lyrics as you type', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const ImportPage()));
    await tester.pump();
    final start = find.widgetWithText(FilledButton, '分离人声，生成音高图');
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    await tester.enterText(find.byType(TextField).last, lyrics);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('2 句，17 个字'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('2 句，17 个字'), findsOneWidget);
    // Back to the top, then switch to "already separated vocals".
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('这是已经分离好的纯人声'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('生成逐字音高图'), findsOneWidget);
    await screenshot(tester, '5_import');
  });

  testWidgets('settings page shows the model status and practice options', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const SettingsPage()));
    await tester.pump();
    expect(find.text('人声分离和去和声'), findsOneWidget);
    expect(find.text('还没有下载（194 MB）'), findsOneWidget);
    expect(find.text('忽略八度'), findsOneWidget);
    await screenshot(tester, '6_settings');
    // The download sheet names both models and credits their authors.
    await tester.tap(find.widgetWithText(TextButton, '下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('下载分离模型'), findsOneWidget);
    expect(find.text('人声分离'), findsOneWidget);
    expect(find.text('去和声'), findsOneWidget);
    expect(find.textContaining('Ultimate Vocal Remover'), findsOneWidget);
    await screenshot(tester, '7_model_download');
  });

  testWidgets('about page credits the models and opens the licenses', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const AboutPage()));
    await tester.pump();
    expect(find.textContaining('Anjok07 和 aufr33'), findsOneWidget);
    // Further down the app states its own license and where the source is.
    await tester.scrollUntilVisible(find.text('许可全文与开源组件'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('AGPL-3.0'), findsOneWidget);
    expect(find.textContaining('github.com/zhikkz/YinTrace'), findsOneWidget);
    await screenshot(tester, '8_about');
  });

  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];
  testWidgets('practice page scores a singer through the native engine', (tester) async {
    phone(tester);
    final ref = await tester.runAsync(() => services.songs.loadReference(song.id));
    final contour = await tester.runAsync(() => services.songs.loadPitchTrack(song.id));
    late PracticeSession session;
    await tester.pumpWidget(host(
      services,
      PracticePage(
        meta: song,
        reference: ref!,
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
    ));
    await settleIo(tester, rounds: 5);
    expect(session.error, isNull);
    expect(session.started, isTrue);
    session.play();
    final engine = session.engine!;
    // Render the song in 512 frame blocks with the singer as mic input,
    // pumping frames so the page's ticker pulls and scores the capture.
    Future<void> runUntil(double seconds) async {
      while (engine.positionSeconds < seconds) {
        final pos = engine.positionFrame;
        final n = 512;
        final input = Float32List(n);
        for (var i = 0; i < n && pos + i < singer.length; i++) {
          input[i] = singer[pos + i];
        }
        engine.render(n, input: input);
        await tester.pump(const Duration(milliseconds: 11));
      }
    }

    await runUntil(7.9);
    expect(find.textContaining('记得带伞'), findsWidgets);
    await screenshot(tester, '3_practice');
    await runUntil(9.9);
    final results = session.scorer.results();
    expect(results.every((r) => r.attempted), isTrue);
    final line1 = results[0];
    expect(line1.tokens[3].issues.map((i) => i.name), contains('flat'));
    expect(line1.tokens[8].issues.map((i) => i.name), contains('missed'));
    expect(line1.tokens[0].issues, isEmpty);
    expect(results[1].tokens[3].issues.map((i) => i.name), contains('sharp'));
    final overall = session.scorer.overallScore();
    expect(overall, inInclusiveRange(55, 92));

    await tester.tap(find.byTooltip('查看评分'));
    await settleIo(tester, rounds: 40);
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('先练这几个字'), findsOneWidget);
    await screenshot(tester, '4_results');
    final history = await tester.runAsync(() => services.songs.loadHistory(song.id));
    expect(history!.length, 2);
    // Dispose the page (and with it the native engine).
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);
}
