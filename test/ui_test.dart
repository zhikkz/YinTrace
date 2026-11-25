import 'dart:async';
// Widget tests for the main screens. The practice test runs the real
// native engine in offline mode (set YINTRACE_AUDIO_LIB, see
// packages/yintrace_audio/tool/run_dart_tests.sh) with a synthetic singer
// fed into the microphone input.
//
// Set SCREENSHOT_DIR to also write PNG screenshots.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/manual_timing.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/app/screen_awake.dart';
import 'package:yintrace/src/app/licenses.dart' show appSourceUrl;
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/app/update_check.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/ui/model_setup.dart';
import 'package:yintrace/src/practice/latency_calibration.dart';
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/practice/scoring.dart';
import 'package:yintrace/src/practice/segment_player.dart';
import 'package:yintrace/src/practice/take_recorder.dart';
import 'package:yintrace/src/export/recordings.dart';
import 'package:yintrace/src/ui/about_page.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace/src/ui/benchmark_page.dart';
import 'package:yintrace/src/ui/export_page.dart';
import 'package:yintrace/src/ui/import_page.dart';
import 'package:yintrace/src/ui/import_queue_page.dart';
import 'package:yintrace/src/ui/library_page.dart';
import 'package:yintrace/src/ui/latency_calibration_dialog.dart';
import 'package:yintrace/src/ui/pitch_editor_page.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';
import 'package:yintrace/src/ui/settings_page.dart';
import 'package:yintrace/src/ui/practice_page.dart';
import 'package:yintrace/src/ui/results_sheet.dart';
import 'package:yintrace/src/ui/score_trend.dart';
import 'package:yintrace/src/ui/song_page.dart';
import 'package:yintrace/src/ui/song_share.dart';
import 'package:yintrace/src/ui/tuner_page.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'support/benchmark_sample.dart';
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
    child: MaterialApp(debugShowCheckedModeBanner: false, theme: YinTraceApp.theme(Brightness.light), home: home),
  ),
);

class _FakeLatencyMeasurer implements LatencyMeasurer {
  _FakeLatencyMeasurer(this.outputRoute, this.results);

  @override
  OutputRoute outputRoute;
  final List<LatencyCalibrationResult> results;
  final calls = <(LatencyCalibrationMethod, bool)>[];
  void Function()? onMeasure;

  @override
  Future<LatencyCalibrationResult> measure(
    LatencyCalibrationMethod method, {
    required bool measurement,
    required LatencyCalibrationControl control,
    required void Function(LatencyCalibrationProgress) onProgress,
  }) async {
    calls.add((method, measurement));
    onMeasure?.call();
    return results.removeAt(0);
  }
}

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
      models: ModelManager(dir: Directory('${tmp.path}/models'), loadRecipe: (_) => throw StateError('unused')),
    );
    // A "pure vocal" + accompaniment import (no models needed).
    final m = melody();
    final voice = synthVoice(m, 10);
    final acc = Float32List(voice.length * 2);
    writeWavFile('${tmp.path}/vocal.wav', voice, 1, sr);
    writeWavFile('${tmp.path}/acc.wav', acc, 2, sr);
    song =
        await ImportPipeline(
          audio: const WavAudioBackend(),
          repository: songs,
          loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
        ).run(
          ImportRequest(
            audioPath: '${tmp.path}/vocal.wav',
            accompanimentPath: '${tmp.path}/acc.wav',
            lyrics: lyrics,
            title: '夜航（示例）',
            artist: '演示',
            vocalsOnly: true,
          ),
        );
    await songs.addPractice(song.id, PracticeRecord(at: DateTime.now(), score: 74, lineScores: {0: 80, 1: 66}));
    await songs.addPractice(song.id, PracticeRecord(at: DateTime.now(), score: 82, lineScores: {0: 88, 1: 71}));
    // The singer: right on most characters, flat on 3–4, sharp on line 2's
    // 4th character, skipping the 9th character.
    final sung = <Syl>[
      for (var i = 0; i < m.length; i++)
        if (i != 8) Syl(m[i].start + 0.02, m[i].end, m[i].midi + (i == 3 || i == 4 ? -0.7 : (i == 13 ? 0.9 : 0.05))),
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
    expect(find.textContaining('今天练过'), findsOneWidget);
    // The separation models are not installed: the library offers them.
    expect(find.textContaining('人声分离模型（67 MB）'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '下载'), findsOneWidget);
    await screenshot(tester, '1_library');
  });

  testWidgets('an empty library says what a song needs, and offers free practice', (tester) async {
    phone(tester);
    final empty = AppServices(
      settings: AppSettings(null),
      songs: SongRepository(Directory('${tmp.path}/no-songs')),
      models: services.models,
    );
    await tester.pumpWidget(host(empty, const LibraryPage()));
    await settleIo(tester);
    expect(find.text('从第一首歌开始'), findsOneWidget);
    expect(find.text('准备一首歌'), findsOneWidget);
    expect(find.text('跟着唱'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '导入歌曲'), findsOneWidget);
    expect(find.textContaining('试试自由练习'), findsOneWidget);
    await screenshot(tester, '1b_library_empty');
  });

  testWidgets('song page shows the per-character pitch map', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, SongPage(songId: song.id)));
    await settleIo(tester, rounds: 40);
    await screenshot(tester, '2_song');
    expect(find.text('夜里的风慢慢吹过窗台'), findsOneWidget);
    expect(find.text('下雨了 记得带伞'), findsOneWidget);
    expect(find.text('88'), findsOneWidget);
    // Two whole-song runs: the trend and each line's sparkline appear.
    expect(find.text('得分趋势'), findsOneWidget);
    expect(find.text('最近 82 分，比第一次高 8 分'), findsOneWidget);
    expect(find.byType(LineScoreSparkline), findsNWidgets(2));
    // Every line can be corrected.
    expect(find.byTooltip('校正这一句'), findsNWidgets(2));
    // The line under 80 the last time is suggested first; the whole song
    // is one tap away at the bottom.
    expect(find.text('先练这几句'), findsOneWidget);
    expect(find.widgetWithText(ActionChip, '下雨了 记得带…  71 分'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '整首练习'), findsOneWidget);
  });

  testWidgets('an imported song can be renamed from its menu', (tester) async {
    phone(tester);
    final source = services.songs;
    final repo = SongRepository(Directory('${tmp.path}/rename'));
    repo.dirFor(song.id).createSync(recursive: true);
    for (final file in source.dirFor(song.id).listSync().whereType<File>()) {
      file.copySync(repo.pathFor(song.id, file.uri.pathSegments.last));
    }
    final renameServices = AppServices(settings: AppSettings(null), songs: repo, models: services.models);
    await tester.pumpWidget(host(renameServices, const LibraryPage()));
    await settleIo(tester);
    await tester.tap(find.text(song.title));
    await settleIo(tester, rounds: 40);

    Future<void> openRename() async {
      await tester.tap(find.byType(PopupMenuButton<String>));
      await tester.pumpAndSettle();
      await tester.tap(find.text('修改歌名'));
      await tester.pumpAndSettle();
    }

    String? songPageTitle() => (tester.widget<SliverAppBar>(find.byType(SliverAppBar)).title as Text).data;

    await openRename();
    final field = find.byType(TextFormField);
    expect(tester.widget<TextFormField>(field).initialValue, song.title);
    await tester.enterText(field, '   ');
    await tester.tap(find.widgetWithText(FilledButton, '保存'));
    await tester.pumpAndSettle();
    expect(find.text('请输入歌名'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(songPageTitle(), song.title);

    await openRename();
    await tester.enterText(field, '  夜航新名  ');
    await tester.testTextInput.receiveAction(TextInputAction.done);
    await settleIo(tester, rounds: 30);
    expect(songPageTitle(), '夜航新名');
    expect(find.text('得分趋势'), findsOneWidget);
    await tester.pageBack();
    await settleIo(tester, rounds: 30);
    expect(find.text('夜航新名'), findsOneWidget);
    expect(find.text('82'), findsOneWidget);

    final stored = await tester.runAsync(() => SongRepository(repo.root).load(song.id));
    expect(stored?.title, '夜航新名');
    expect(stored?.artist, song.artist);
    expect(stored?.lyrics, song.lyrics);
  });

  AppServices newEditorServices() {
    final library = SongRepository(tmp.createTempSync('correction_'));
    final folder = library.dirFor(song.id)..createSync();
    for (final file in services.songs.dirFor(song.id).listSync().whereType<File>()) {
      file.copySync('${folder.path}/${file.uri.pathSegments.last}');
    }
    return AppServices(settings: AppSettings(null), songs: library, models: services.models);
  }

  Future<void> waitForEditor(WidgetTester tester, bool Function() ready, String detail) async {
    for (var round = 0; round < 200 && !ready(); round++) {
      await settleIo(tester, rounds: 1);
    }
    expect(ready(), isTrue, reason: detail);
  }

  Future<void> editorIdle(WidgetTester tester, AppServices editorServices) async {
    await tester.pump();
    await waitForEditor(tester, () => !editorServices.pitchCorrections.busyFor(song.id), 'all correction work has finished');
  }

  testWidgets('pitch editor moves a character, leaves it out of the score and restores it', (tester) async {
    phone(tester);
    final editorServices = newEditorServices();
    await tester.runAsync(() => editorServices.songs.saveTranspose(song.id, 2));
    late SegmentPlayer player;
    try {
      await tester.pumpWidget(
        host(
          editorServices,
          PitchEditorPage(
            songId: song.id,
            line: 1,
            decodeInBackground: false,
            playerFactory: () => player = SegmentPlayer(
              engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
              configureSession: false,
            ),
          ),
        ),
      );
      await editorIdle(tester, editorServices);
      expect(find.text('第 2 句，共 2 句'), findsOneWidget);
      await tester.tap(find.text('记'));
      await tester.pump();
      expect(find.text('「记」'), findsOneWidget);
      Future<RefToken> stored() async =>
          (await tester.runAsync(() => editorServices.songs.loadReference(song.id)))!.lines[1].tokens[3];
      final detected = (await stored()).notes.first.midi;
      await screenshot(tester, '2b_pitch_editor');
      await tester.tap(find.text('修改拼音'));
      await settleIo(tester, rounds: 15);
      await tester.pumpAndSettle();
      expect(find.text('修改「记」的拼音'), findsOneWidget);
      expect(find.text('自动读音：ji'), findsOneWidget);
      await tester.tap(find.text('取消'));
      await tester.pumpAndSettle();

      // Listen to the original: exactly the vocal around the character.
      await tester.tap(find.text('听原唱'));
      await waitForEditor(tester, () => player.engine?.isPlaying == true, 'the original vocal starts playing');
      final engine = player.engine!;
      expect(engine.isPlaying, isTrue);
      final ref = await tester.runAsync(() => editorServices.songs.loadReference(song.id));
      final from = ref!.lines[1].tokens[3].start - 0.12;
      final vocal = readWavFile(editorServices.songs.pathFor(song.id, song.vocalsFile)).samples;
      final heard = engine.render(2048);
      final a = (from * sr).round();
      var err = 0.0;
      for (var i = 0; i < 2048; i++) {
        err = math.max(err, (heard[2 * i] - vocal[a + i]).abs());
      }
      expect(err, lessThan(1e-3));
      engine.render(sr); // to its end
      expect(engine.isPlaying, isFalse);

      await tester.tap(find.text('升八度'));
      await editorIdle(tester, editorServices);
      expect((await stored()).notes.first.midi, closeTo(detected + 12, 1e-6));
      expect(find.textContaining('调高了 1 个八度'), findsOneWidget);
      await tester.tap(find.text('降半音'));
      await editorIdle(tester, editorServices);
      expect((await stored()).shift, 11);
      // Quick taps: every one is saved, in order.
      for (var i = 0; i < 3; i++) {
        await tester.tap(find.text('升半音'));
        await tester.pump();
      }
      await editorIdle(tester, editorServices);
      expect((await stored()).shift, 14);
      expect(find.textContaining('调高了 14 个半音'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('这个字不计分'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('这个字不计分'));
      await editorIdle(tester, editorServices);
      expect((await stored()).skip, isTrue);
      expect(find.text('不计分'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('恢复自动识别'), 200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('恢复自动识别'));
      await editorIdle(tester, editorServices);
      final restored = await stored();
      expect(restored.notes.first.midi, closeTo(detected, 1e-6));
      expect(restored.corrected, isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await editorIdle(tester, editorServices);
    }
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

  testWidgets('pitch editor sets where a character starts, and the rest of the line follows', (tester) async {
    phone(tester);
    final editorServices = newEditorServices();
    var alignments = 0;
    try {
      await tester.pumpWidget(
        host(
          editorServices,
          PitchEditorPage(
            songId: song.id,
            line: 1,
            decodeInBackground: false,
            playerFactory: () => SegmentPlayer(
              engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
              configureSession: false,
            ),
            retimer: (track, lines, ref, line, pins) async {
              alignments++;
              return retimeLine(track, lines, ref, line, pins);
            },
          ),
        ),
      );
      await editorIdle(tester, editorServices);
      Future<SongReference> stored() async => (await tester.runAsync(() => editorServices.songs.loadReference(song.id)))!;
      final before = await stored();
      final token = before.lines[1].tokens[4];
      final start = token.start;
      final firstLine = [for (final t in before.lines[0].tokens) (t.start, t.end, t.notes.length)];
      await tester.tap(find.text('得'));
      await tester.pump();
      final shown = find.textContaining(RegExp(r'^从 \d+:\d\d\.\d\d 开始$'));
      expect(shown, findsOneWidget);

      // Each tap updates the displayed start and restarts the save window.
      await tester.scrollUntilVisible(find.byTooltip('推后 0.05 秒'), 200, scrollable: find.byType(Scrollable).first);
      final displayedStart = tester.widget<Text>(shown).data;
      final graph = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter);
      PitchGraphPainter painter() => tester.widget<CustomPaint>(graph).painter! as PitchGraphPainter;
      final initialPainter = painter();
      final size = tester.getSize(graph);
      final note = token.notes.first;
      void expectPreview(double shift) {
        final current = painter();
        expect(current.contour, same(initialPainter.contour));
        expect((current.t0, current.t1), (initialPainter.t0, initialPainter.t1));
        expect(current.highlight!.$1, closeTo(token.slotStart + shift, 1e-6));
        expect(current.highlight!.$2, closeTo(token.end + shift, 1e-6));

        double x(double time) => current.gutter + (time - current.t0) / (current.t1 - current.t0) * (size.width - current.gutter);
        final y = size.height - (note.midi - current.midiLo) / (current.midiHi - current.midiLo) * size.height;
        expect(graph, paints..something((method, args) {
          if (method != #drawLine) return false;
          final stroke = args[2] as Paint;
          if (stroke.strokeCap != StrokeCap.round) return false;
          final left = x(note.start + shift) + stroke.strokeWidth / 2;
          final right = math.max(x(note.end + shift) - stroke.strokeWidth / 2, left + 0.5);
          return ((args[0] as Offset) - Offset(left, y)).distance < 1e-6 &&
              ((args[1] as Offset) - Offset(right, y)).distance < 1e-6;
        }));
      }

      expectPreview(0);
      await tester.tap(find.byTooltip('推后 0.05 秒'));
      await tester.pump(const Duration(milliseconds: 200));
      expect(tester.widget<Text>(shown).data, isNot(displayedStart));
      expectPreview(0.05);
      await tester.tap(find.byTooltip('推后 0.05 秒'));
      await tester.pump(const Duration(milliseconds: 200));
      expectPreview(0.1);
      expect(alignments, 0);
      expect((await stored()).lines[1].tokens[4].pinned, isNull);
      await editorIdle(tester, editorServices);
      expect(alignments, 1);
      final moved = (await stored()).lines[1];
      expect(moved.tokens[4].pinned, closeTo(start + 0.1, 1e-3));
      // Its voice starts there (to the pitch frame, 5.8 ms), and the
      // character before now ends there.
      expect(moved.tokens[4].start, greaterThanOrEqualTo(moved.tokens[4].pinned! - 0.003));
      expect(moved.tokens[3].end, lessThanOrEqualTo(moved.tokens[4].pinned! + 0.003));
      expect(find.text('你调过'), findsOneWidget);
      await screenshot(tester, '2c_pitch_editor_timing');
      // The other line did not move.
      expect([for (final t in (await stored()).lines[0].tokens) (t.start, t.end, t.notes.length)], firstLine);

      // A long press on the graph puts the start of the selected character
      // there.
      await tester.scrollUntilVisible(find.text('带'), -200, scrollable: find.byType(Scrollable).first);
      await tester.tap(find.text('带'));
      await tester.pump();
      await tester.longPress(graph);
      await editorIdle(tester, editorServices);
      expect((await stored()).lines[1].tokens[5].pinned, isNotNull);

      // Restoring the line puts every character back where the aligner has it.
      await tester.tap(find.byIcon(Icons.more_horiz_rounded));
      await tester.pumpAndSettle();
      await tester.tap(find.text('这一句全部恢复自动识别'));
      await editorIdle(tester, editorServices);
      final restored = (await stored()).lines[1];
      expect(restored.tokens.every((t) => t.pinned == null), isTrue);
      expect(restored.tokens[4].start, closeTo(start, 1e-6));
      expect(restored.tokens.any((t) => t.corrected), isFalse);
    } finally {
      await tester.pumpWidget(const SizedBox());
      await editorIdle(tester, editorServices);
    }
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

  for (final useModel in [false, true]) {
    final aligner = useModel ? 'HuBERTFA' : 'pitch alignment';
    testWidgets('pitch editor keeps taps while $aligner is running', (tester) async {
      phone(tester);
      final editorServices = newEditorServices();
      if (useModel) {
        final repo = editorServices.songs;
        final original = (await tester.runAsync(() => repo.load(song.id)))!;
        await tester.runAsync(
          () => repo.saveAlignmentMetadata(song.id, original.lyrics, {...original.modelInfo, 'alignment': 'HuBERTFA'}),
        );
      }
      // Each re-alignment waits until the test lets it finish, as on the
      // phone, where it runs in the background.
      final gates = <Completer<void>>[];
      var holdAlignment = true;
      try {
        await tester.pumpWidget(
          host(
            editorServices,
            PitchEditorPage(
              songId: song.id,
              line: 1,
              decodeInBackground: false,
              playerFactory: () => SegmentPlayer(
                engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
                configureSession: false,
              ),
              retimer: (track, lines, ref, line, pins) async {
                if (holdAlignment) {
                  final gate = Completer<void>();
                  gates.add(gate);
                  await gate.future;
                }
                return retimeLine(track, lines, ref, line, pins);
              },
            ),
          ),
        );
        await editorIdle(tester, editorServices);
        Future<SongReference> stored() async => (await tester.runAsync(() => editorServices.songs.loadReference(song.id)))!;
        final original = await stored();
        final before = original.lines[1];
        final scrollable = find.byType(Scrollable).first;
        Future<void> nudge(String char) async {
          await tester.scrollUntilVisible(find.text(char), -200, scrollable: scrollable);
          await tester.tap(find.text(char));
          await tester.pump();
          await tester.scrollUntilVisible(find.byTooltip('推后 0.05 秒'), 200, scrollable: scrollable);
          await tester.tap(find.byTooltip('推后 0.05 秒'));
          await tester.pump();
        }

        // Twice on one character, then once on another of the same line, all
        // before the first result is in.
        await nudge('得');
        await tester.pump(const Duration(milliseconds: 250));
        expect(gates, hasLength(1));
        await tester.tap(find.byTooltip('推后 0.05 秒'));
        await tester.pump();
        expect(find.text('你调过'), findsOneWidget);
        await nudge('带');
        expect(gates, hasLength(1));
        final graph = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter);
        final preview = tester.widget<CustomPaint>(graph).painter! as PitchGraphPainter;
        final tokens = preview.reference!.lines.single.tokens;
        expect(preview.tokenTimeOffsets[tokens[4]], closeTo(0.1, 1e-6));
        expect(preview.tokenTimeOffsets[tokens[5]], closeTo(0.05, 1e-6));
        gates.first.complete();
        await tester.pump();
        expect((await stored()).lines[1].tokens[4].pinned, isNull);
        await tester.pump(const Duration(milliseconds: 250));
        expect(gates, hasLength(2));
        gates.last.complete();
        await editorIdle(tester, editorServices);
        final after = (await stored()).lines[1];
        expect(after.tokens[4].pinned, closeTo(before.tokens[4].start + 0.1, 1e-3));
        expect(after.tokens[5].pinned, closeTo(before.tokens[5].start + 0.05, 1e-3));
      } finally {
        holdAlignment = false;
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        await tester.pumpWidget(const SizedBox());
        await editorIdle(tester, editorServices);
      }
    });
  }

  for (final running in [false, true]) {
    final work = running ? 'the latest in-flight edit' : 'a debounced edit';
    testWidgets('pitch editor returns immediately and saves $work in the background', (tester) async {
      phone(tester);
      final editorServices = newEditorServices();
      Future<SongReference> stored() async => (await tester.runAsync(() => editorServices.songs.loadReference(song.id)))!;
      final before = await stored();
      final gates = <Completer<void>>[];
      var holdAlignment = true;
      try {
        await tester.pumpWidget(
          host(
            editorServices,
            Builder(
              builder: (context) => Scaffold(
                body: TextButton(
                  onPressed: () => Navigator.of(context).push(MaterialPageRoute<void>(
                    builder: (_) => PitchEditorPage(
                      songId: song.id,
                      line: 1,
                      decodeInBackground: false,
                      retimer: (track, lines, ref, line, pins) async {
                        if (holdAlignment) {
                          final gate = Completer<void>();
                          gates.add(gate);
                          await gate.future;
                        }
                        return retimeLine(track, lines, ref, line, pins);
                      },
                    ),
                  )),
                  child: const Text('打开校正'),
                ),
              ),
            ),
          ),
        );
        await tester.tap(find.text('打开校正'));
        await editorIdle(tester, editorServices);
        await tester.pumpAndSettle();
        await tester.tap(find.text('得'));
        await tester.pump();
        await tester.scrollUntilVisible(find.byTooltip('推后 0.05 秒'), 200, scrollable: find.byType(Scrollable).first);
        final nudge = find.byTooltip('推后 0.05 秒');
        await tester.tap(nudge);
        if (running) {
          await tester.pump(const Duration(milliseconds: 250));
          expect(gates, hasLength(1));
          await tester.tap(nudge);
        }
        await tester.pump();
        expect(gates, hasLength(running ? 1 : 0));

        if (running) {
          await tester.binding.handlePopRoute();
        } else {
          await tester.tap(find.byType(BackButton));
        }
        await tester.pump();
        expect(gates, hasLength(running ? 1 : 0));
        await tester.pumpAndSettle();
        expect(ModalRoute.of(tester.element(find.text('打开校正')))?.isCurrent, isTrue);
        expect(find.text('校正'), findsNothing);
        expect(gates, hasLength(1));
        expect((await stored()).lines[1].tokens[4].pinned, isNull);

        if (running) {
          // Reopening before the previous result arrives keeps the same draft.
          await tester.tap(find.text('打开校正'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          final graph = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter);
          final preview = tester.widget<CustomPaint>(graph).painter! as PitchGraphPainter;
          expect(preview.tokenTimeOffsets[preview.reference!.lines.single.tokens[4]], closeTo(0.1, 1e-6));
          await tester.tap(find.text('得'));
          await tester.pump();
          await tester.scrollUntilVisible(nudge, 200, scrollable: find.byType(Scrollable).first);
          await tester.tap(nudge);
          await tester.tap(find.byType(BackButton));
          await tester.pumpAndSettle();
          expect(find.text('校正'), findsNothing);
          gates.first.complete();
          await tester.pump();
          expect(gates, hasLength(2));
          expect((await stored()).lines[1].tokens[4].pinned, isNull);
        }
        gates.last.complete();
        await editorIdle(tester, editorServices);
        final shift = running ? 0.15 : 0.05;
        expect((await stored()).lines[1].tokens[4].pinned, closeTo(before.lines[1].tokens[4].slotStart + shift, 1e-3));
      } finally {
        holdAlignment = false;
        for (final gate in gates) {
          if (!gate.isCompleted) gate.complete();
        }
        await tester.pumpWidget(const SizedBox());
        await editorIdle(tester, editorServices);
      }
    });
  }

  testWidgets('a kept take becomes a finished track', (tester) async {
    phone(tester);
    final take = TakeRecorder(sampleRate: sr, lengthFrames: 10 * sr);
    final a = sr, b = (9.5 * sr).round();
    take.addAudio(Float32List.sublistView(singer, a, b), a, 0);
    final rec = (await tester.runAsync(
      () => keepTake(services.songs, song.id, take, score: 80, audio: const WavAudioBackend(), background: false),
    ))!;
    final out = Directory('${tmp.path}/exports');
    String? shared;
    late PracticeEngine engine;
    final awake = <bool>[];
    final platform = ScreenAwake.platform;
    ScreenAwake.platform = (on) async => awake.add(on);
    addTearDown(() => ScreenAwake.platform = platform);
    await tester.pumpWidget(
      host(
        services,
        ExportPage(
          songId: song.id,
          recordingId: rec.id,
          engineFactory: () => engine = PracticeEngine.create(mode: EngineMode.offline),
          background: false,
          outputDir: out,
          share: (path) {
            shared = path;
            return true;
          },
        ),
      ),
    );
    await settleIo(tester, rounds: 20);
    expect(find.text('人声 + 伴奏'), findsOneWidget);
    expect(find.textContaining('80 分'), findsOneWidget);
    await screenshot(tester, '4d_export');
    // The preview plays the voice where it was sung.
    expect(awake, isEmpty);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(engine.isPlaying, isTrue);
    expect(awake, [true], reason: 'the screen stays on while the preview plays');
    engine.seek(const Duration(milliseconds: 1500));
    final heard = engine.render(4096);
    expect(heard.fold<double>(0, (m, v) => math.max(m, v.abs())), greaterThan(0.05));
    engine.seek(const Duration(milliseconds: 400));
    final before = engine.render(4096);
    expect(before.fold<double>(0, (m, v) => math.max(m, v.abs())), lessThan(1e-3), reason: 'nothing sung yet');
    final preview = find.byType(Slider).first;
    final beforeDrag = engine.positionFrame;
    final drag = await tester.startGesture(tester.getCenter(preview));
    await drag.moveBy(const Offset(45, 0));
    await tester.pump();
    final target = tester.widget<Slider>(preview).value;
    expect(target, greaterThan(5));
    expect(find.byIcon(Icons.pause_rounded), findsOneWidget);
    expect(engine.render(64), everyElement(0));
    expect(engine.positionFrame, beforeDrag);
    await drag.up();
    expect(engine.isPlaying, isTrue);
    expect(engine.positionSeconds, closeTo(target, 0.001));
    final canceled = await tester.startGesture(tester.getCenter(preview));
    await canceled.moveBy(const Offset(-45, 0));
    expect(engine.render(64), everyElement(0));
    await canceled.cancel();
    expect(engine.isPlaying, isTrue);
    expect(engine.positionSeconds, closeTo(target, 0.001));
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(awake, [true, false]);
    // Played to its end, the preview lets the screen go dark again.
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    engine.seek(Duration(milliseconds: (engine.lengthSeconds * 1000).round() - 50));
    engine.render(sr);
    expect(engine.isPlaying, isFalse);
    await tester.pump(const Duration(milliseconds: 150));
    expect(awake, [true, false, true, false]);
    // Move the voice 100 ms earlier and export.
    final align = find.byType(Slider).at(4);
    await tester.drag(align, const Offset(-60, 0));
    await tester.pump();
    await tester.scrollUntilVisible(find.text('导出成品'), 300, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('导出成品'));
    await tester.pumpAndSettle();
    expect(find.text('版权提示'), findsOneWidget);
    expect(shared, isNull);
    await tester.tap(find.text('确认并导出及分享'));
    await settleIo(tester, rounds: 20);
    expect(shared, isNotNull);
    expect(File(shared!).existsSync(), isTrue);
    expect(shared, contains('我的演唱'));
    expect(find.textContaining('已导出'), findsOneWidget);
    final mix = readWavFile(shared!);
    expect(mix.channels, 2);
    expect(mix.frames, greaterThanOrEqualTo(10 * sr));
    await tester.pumpWidget(const SizedBox());
    await settleIo(tester, rounds: 3);
    final saved = (await tester.runAsync(() => services.songs.loadRecordings(song.id)))!
        .firstWhere((r) => r.id == rec.id);
    expect(saved.mix.offsetMs, lessThan(0), reason: 'the alignment is remembered');
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

  testWidgets('an English song reads as words', (tester) async {
    phone(tester);
    // Written for this test.
    const english = '[00:01.00]Morning comes over the river\n[00:05.00]Carry the light on your shoulder\n';
    final syllables = <Syl>[];
    var t = 1.1;
    for (final m in const <double>[64, 62, 67, 65, 64, 61, 59, 62]) {
      syllables.add(Syl(t, t + 0.3, m));
      t += 0.38;
    }
    t = 5.1;
    for (final m in const <double>[67, 69, 67, 72, 70, 68, 66, 63]) {
      syllables.add(Syl(t, t + 0.3, m));
      t += 0.38;
    }
    final voice = synthVoice(syllables, 9);
    final dir = Directory('${tmp.path}/english')..createSync();
    writeWavFile('${dir.path}/vocal.wav', voice, 1, sr);
    final meta = (await tester.runAsync(
      () =>
          ImportPipeline(
            audio: const WavAudioBackend(),
            repository: services.songs,
            loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
          ).run(
            ImportRequest(
              audioPath: '${dir.path}/vocal.wav',
              lyrics: english,
              title: 'Morning River',
              vocalsOnly: true,
            ),
          ),
    ))!;
    final ref = (await tester.runAsync(() => services.songs.loadReference(meta.id)))!;
    expect(ref.language.code, 'en');
    expect(ref.lines[0].tokens.map((t) => t.text), ['Morning', 'comes', 'over', 'the', 'river']);
    expect(ref.lines[0].tokenText, 'Morning comes over the river');
    await tester.pumpWidget(host(services, SongPage(songId: meta.id)));
    await settleIo(tester, rounds: 30);
    expect(find.text('Morning comes over the river'), findsOneWidget);
    expect(find.textContaining('哪个词的位置或目标音不对'), findsOneWidget);
    await screenshot(tester, '2c_english_song');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('a Japanese song keeps its kana together and Japanese glyphs', (tester) async {
    phone(tester);
    // Written for this test.
    // ...with a Chinese translation under each line, the way players
    // export bilingual lyrics.
    const japanese = '[00:01.00]きょうも空(そら)はあおい\n[00:01.00]今天的天空也很蓝\n'
        '[00:05.00]まっすぐ歩(ある)いてゆこう\n[00:05.00]一直往前走吧\n';
    final syllables = <Syl>[];
    var t = 1.1;
    for (final m in const <double>[64, 66, 68, 70, 67, 66, 63, 61, 65]) {
      syllables.add(Syl(t, t + 0.3, m));
      t += 0.38;
    }
    t = 5.1;
    for (final m in const <double>[62, 64, 66, 68, 65, 63, 61, 64, 66, 68]) {
      syllables.add(Syl(t, t + 0.3, m));
      t += 0.38;
    }
    final dir = Directory('${tmp.path}/japanese')..createSync();
    writeWavFile('${dir.path}/vocal.wav', synthVoice(syllables, 10), 1, sr);
    final meta = (await tester.runAsync(
      () => ImportPipeline(
        audio: const WavAudioBackend(),
        repository: services.songs,
        loadModel: (p, {required inputName, required outputName, coreML}) => throw StateError('unused'),
      ).run(ImportRequest(audioPath: '${dir.path}/vocal.wav', lyrics: japanese, title: '空', vocalsOnly: true)),
    ))!;
    final ref = (await tester.runAsync(() => services.songs.loadReference(meta.id)))!;
    expect(ref.language.code, 'ja');
    expect(ref.lines[0].tokens.map((t) => t.text), ['きょ', 'う', 'も', '空', 'は', 'あ', 'お', 'い']);
    expect(ref.lines[1].tokens.first.text, 'まっ');
    // The translations are not lines of their own, and the lines they
    // belong to have their melody.
    expect(ref.lines, hasLength(2));
    expect(ref.lines[0].tokens.every((t) => t.hasPitch), isTrue);
    await tester.pumpWidget(host(services, SongPage(songId: meta.id)));
    await settleIo(tester, rounds: 30);
    final line = tester.widget<Text>(find.text('きょうも空(そら)はあおい'));
    expect(line.style?.locale, const Locale('ja', 'JP'));
    expect(find.text('今天的天空也很蓝'), findsOneWidget);
    expect(find.text('一直往前走吧'), findsOneWidget);
    await screenshot(tester, '2d_japanese_song');
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('import page validates the timed lyrics as you type', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const ImportPage()));
    await tester.pump();
    final start = find.widgetWithText(FilledButton, '分离人声，生成音高图');
    expect(tester.widget<FilledButton>(start).onPressed, isNull);
    // ...and says why.
    expect(find.text('还差：选择音频；粘贴带时间的歌词'), findsOneWidget);
    // Removing the harmony is slow, so it is off unless asked for.
    final harmony = find.widgetWithText(SwitchListTile, '去和声');
    expect(tester.widget<SwitchListTile>(harmony).value, isFalse);
    expect(find.text('这一步耗时较长，和声明显时再打开'), findsOneWidget);
    await screenshot(tester, '5a_import_start');
    await tester.scrollUntilVisible(find.text('从文件读取 .lrc'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(); // builds the lyrics field below it
    await tester.enterText(find.byType(TextField).last, lyrics);
    await tester.pump();
    await tester.scrollUntilVisible(find.text('2 句，17 个字（中文）'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('2 句，17 个字（中文）'), findsOneWidget);
    expect(find.text('还差：选择音频'), findsOneWidget);
    // Bilingual lyrics: the page says what it did with the translation lines.
    await tester.enterText(
      find.byType(TextField).last,
      '[00:01.00]夜里的风慢慢吹过窗台\n[00:01.00]The night wind blows past the window\n'
      '[00:06.50]下雨了 记得带伞\n[00:06.50]Take an umbrella when it rains\n',
    );
    await tester.pump();
    expect(find.text('2 句，17 个字（中文）。另有 2 行和上一行时间相同，当作翻译，不计入要唱的句子'), findsOneWidget);
    await tester.enterText(find.byType(TextField).last, lyrics);
    await tester.pump();
    // Back to the top. A song file someone sent is the other way in: the
    // page shows only that, and coming back keeps what was typed.
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.text('导入yintrace文件'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('导入音迹歌曲文件'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '选择音迹文件'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('选择音频'), findsNothing);
    expect(find.text('去和声'), findsNothing);
    expect(find.widgetWithText(FilledButton, '分离人声，生成音高图'), findsNothing);
    await screenshot(tester, '5b_import_song_file');
    await tester.tap(find.text('添加新歌曲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('导入音迹歌曲文件'), findsNothing);
    await tester.scrollUntilVisible(find.text('从文件读取 .lrc'), 200, scrollable: find.byType(Scrollable).first);
    await tester.pump(); // builds the lyrics field below it
    expect(tester.widget<TextField>(find.byType(TextField).last).controller!.text, lyrics);
    await tester.drag(find.byType(Scrollable).first, const Offset(0, 3000));
    await tester.pump(const Duration(milliseconds: 500));
    // Then switch to "already separated vocals".
    await tester.tap(find.text('这是已经分离好的纯人声'));
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('生成逐字音高图'), findsOneWidget);
    await screenshot(tester, '5_import');
  });

  testWidgets('lyrics come from the clipboard or a .lrc file, and their tags name the song', (tester) async {
    phone(tester);
    final lrc = File('${tmp.path}/song.lrc')
      ..writeAsBytesSync([0xEF, 0xBB, 0xBF, ...utf8.encode('[ti:夜航]\n[ar:演示]\n$lyrics')]);
    // "[00:01.00]夜里" saved as GBK.
    final gbk = File('${tmp.path}/gbk.lrc')..writeAsBytesSync([...'[00:01.00]'.codeUnits, 0xD2, 0xB9, 0xC0, 0xEF]);
    var picked = gbk.path;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.getData') return <String, dynamic>{'text': '$lyrics\n'};
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    await tester.pumpWidget(host(services, ImportPage(pickLyricsFile: () async => picked)));
    await tester.pump();
    final scrollable = find.byType(Scrollable).first;
    String lyricsField() => tester.widget<TextField>(find.byType(TextField).last).controller!.text;

    // Another encoding is refused, with what to do instead.
    await tester.scrollUntilVisible(find.text('从文件读取 .lrc'), 200, scrollable: scrollable);
    await tester.pump(); // builds the lyrics field below it
    await tester.tap(find.text('从文件读取 .lrc'));
    await settleIo(tester, rounds: 10);
    await tester.pump(const Duration(milliseconds: 300));
    expect(find.textContaining('另存为 UTF-8'), findsOneWidget);
    expect(lyricsField(), isEmpty);
    expect(gbk.existsSync(), isTrue, reason: 'only the picker\'s own copies are deleted');

    await tester.tap(find.text('粘贴'));
    await settleIo(tester, rounds: 10);
    expect(lyricsField(), lyrics.trim());
    expect(find.text('还差：选择音频'), findsOneWidget);

    // A .lrc file (UTF-8 with a byte order mark) replaces what was there,
    // which can be had back; its tags name the song.
    picked = lrc.path;
    await tester.tap(find.text('从文件读取 .lrc'));
    await settleIo(tester, rounds: 10);
    await tester.pump(const Duration(milliseconds: 300));
    expect(lyricsField(), startsWith('[ti:夜航]'));
    expect(find.text('已替换原来的歌词'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('歌曲信息'), -200, scrollable: scrollable);
    expect(find.text('夜航'), findsOneWidget);
    expect(find.text('演示'), findsOneWidget);
    await screenshot(tester, '5c_import_lyrics_file');
    tester.widget<SnackBarAction>(find.byType(SnackBarAction)).onPressed(); // 撤销
    await tester.pump();
    expect(lyricsField(), lyrics.trim());
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('the share preview lists exactly the audio included for each song format', (tester) async {
    for (final (acc, original, label) in [
      (null, null, '人声'),
      (null, 'original.mp3', '人声、最初导入的原始音频'),
      ('backing.m4a', 'original.mp3', '人声、伴奏'),
    ]) {
      final meta = SongMeta.fromJson({...song.toJson(), 'accompanimentFile': acc, 'originalFile': original});
      await tester.pumpWidget(host(services, Scaffold(body: SongShareSheet(song: meta))));
      expect(find.textContaining('文件里有$label、歌词'), findsOneWidget);
    }
  });

  testWidgets('a song goes to someone else as one file, and comes into a library from it', (tester) async {
    phone(tester);
    // The song page offers it.
    final before = (await tester.runAsync(services.songs.list))!.map((s) => s.id).toSet();
    await tester.pumpWidget(host(services, SongPage(songId: song.id)));
    await settleIo(tester, rounds: 40);
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('发给别人'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('把这首歌发给别人'), findsOneWidget);
    expect(find.textContaining('不包含你的练习成绩和录音'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '导出歌曲文件'), findsOneWidget);
    await screenshot(tester, '9_share_song');
    await tester.pumpWidget(const SizedBox());

    // Exporting writes the file and hands it to the share sheet.
    final out = Directory('${tmp.path}/shared');
    final shared = <String>[];
    await tester.pumpWidget(
      host(
        services,
        Scaffold(
          body: SongShareSheet(
            song: song,
            background: false,
            outputDir: out,
            share: (path) {
              shared.add(path);
              return true;
            },
          ),
        ),
      ),
    );
    final file = '${out.path}/夜航（示例） - 演示.yintrace';
    await tester.tap(find.text('导出歌曲文件'));
    await tester.pumpAndSettle();
    expect(find.text('版权提示'), findsOneWidget);
    expect(find.textContaining('歌曲文件包含人声、伴奏、歌词'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(shared, isEmpty);
    expect(File(file).existsSync(), isFalse);

    await tester.tap(find.text('导出歌曲文件'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('确认并导出及分享'));
    await settleIo(tester, rounds: 5);
    expect(shared, [file]);
    expect(File(file).lengthSync(), greaterThan(100000));
    expect(find.text('已导出 夜航（示例） - 演示.yintrace'), findsOneWidget);
    await tester.tap(find.text('分享或存到别处'));
    await tester.pumpAndSettle();
    expect(shared, [file]);
    await tester.tap(find.text('确认并分享'));
    await tester.pumpAndSettle();
    expect(shared, [file, file]);
    await tester.pumpWidget(const SizedBox());

    // The receiver can see a package rejected in the queue, then add a valid one.
    String? picked = '${tmp.path}/vocal.wav';
    await tester.pumpWidget(host(services, Scaffold(body: Builder(builder: (context) {
      return TextButton(
        onPressed: () async {
          final added = await Navigator.of(context).push(MaterialPageRoute<bool>(builder: (_) =>
              ImportPage(pickSongFile: () async => picked, background: false)));
          if (added == true && context.mounted) {
            await Navigator.of(context).push(MaterialPageRoute<void>(builder: (_) => const ImportQueuePage()));
          }
        },
        child: const Text('添加文件'),
      );
    }))));
    Future<void> addPackage() async {
      await tester.tap(find.text('添加文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('导入yintrace文件'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, '选择音迹文件'));
      await settleIo(tester, rounds: 35);
    }

    await addPackage();
    expect(find.byType(ImportQueuePage), findsOneWidget);
    expect(find.text('这不是音迹导出的歌曲文件'), findsOneWidget);
    expect(find.text('导入失败'), findsOneWidget);
    await tester.pageBack();
    await tester.pumpAndSettle();
    picked = file;
    await addPackage();
    expect(find.text('已导入'), findsOneWidget);
    expect(find.byType(SongPage), findsNothing);
    await tester.tap(find.text('打开歌曲'));
    await settleIo(tester, rounds: 40);
    expect(find.byType(SongPage), findsOneWidget);
    expect(find.text('夜航（示例）'), findsWidgets);
    expect(find.text('还没练过'), findsOneWidget);
    expect(find.text('我的录音'), findsNothing);
    expect(find.text('夜里的风慢慢吹过窗台'), findsOneWidget);
    final added = (await tester.runAsync(services.songs.list))!.where((s) => !before.contains(s.id)).single;
    expect(added.practiceCount, 0);
    expect((await tester.runAsync(() => services.songs.load(song.id)))!.practiceCount, greaterThan(0));
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => services.songs.delete(added.id));
  });

  testWidgets('model setup only gates on the models required by this import', (tester) async {
    phone(tester);
    Future<bool>? result;
    Widget entry(List<ModelSpec> requiredModels) => host(
      services,
      Scaffold(
        body: Builder(builder: (context) => TextButton(
          onPressed: () => result = ensureModels(context, requiredModels: requiredModels),
          child: const Text('检查模型'),
        )),
      ),
    );
    await tester.pumpWidget(entry(const [vocalModel]));
    await tester.tap(find.text('检查模型'));
    await tester.pumpAndSettle();
    expect(find.text('人声分离'), findsOneWidget);
    expect(find.text('去和声'), findsNothing);
    expect(find.textContaining('本次所需模型共 67 MB'), findsOneWidget);
    // Emulate an installed vocal model (a sparse file; no weights downloaded).
    final file = File('${services.models.dir.path}/${vocalModel.installedName}');
    file.parent.createSync(recursive: true);
    final handle = file.openSync(mode: FileMode.write);
    handle.truncateSync(vocalModel.installedBytes);
    handle.closeSync();
    addTearDown(() {
      if (file.existsSync()) file.deleteSync();
    });
    Navigator.of(tester.element(find.byType(ModelSetupSheet))).pop();
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    await tester.tap(find.text('检查模型'));
    await tester.pumpAndSettle();
    expect(await result, isTrue);
    expect(find.byType(ModelSetupSheet), findsNothing);

    // Enabling harmony still asks for the missing second model.
    await tester.pumpWidget(entry(separationModels));
    await tester.tap(find.text('检查模型'));
    await tester.pumpAndSettle();
    expect(find.text('去和声'), findsOneWidget);
    expect(find.text('127 MB'), findsOneWidget);
    Navigator.of(tester.element(find.byType(ModelSetupSheet))).pop();
    await tester.pumpAndSettle();
    expect(await result, isFalse);

    await tester.pumpWidget(host(services, const LibraryPage()));
    await settleIo(tester);
    expect(find.textContaining('导入整首歌之前'), findsNothing);
    await tester.pumpWidget(host(services, const SettingsPage()));
    await tester.pump();
    expect(find.text('已下载部分模型，占用 67 MB'), findsOneWidget);
    // The vocal model alone can be deleted, without downloading the rest first.
    expect(find.widgetWithText(TextButton, '下载'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, '删除'));
    await tester.pumpAndSettle();
    expect(find.textContaining('可以腾出 67 MB'), findsOneWidget);
    await tester.tap(find.descendant(of: find.byType(AlertDialog), matching: find.text('删除')));
    await tester.pumpAndSettle();
    expect(file.existsSync(), isFalse);
    expect(find.text('还没有下载（194 MB）'), findsOneWidget);
    expect(find.widgetWithText(TextButton, '删除'), findsNothing);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('settings page shows the model status and practice options', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const SettingsPage()));
    await tester.pump();
    expect(find.text('人声分离和去和声'), findsOneWidget);
    expect(find.text('还没有下载（194 MB）'), findsOneWidget);
    expect(find.text('忽略八度'), findsOneWidget);
    // Release builds have no tester tools.
    expect(find.text('测试版'), findsNothing);
    expect(find.text('性能测试'), findsNothing);
    expect(find.text('只用备用线路重新下载模型'), findsNothing);
    await screenshot(tester, '6_settings');
    // The download sheet names both models and credits their authors.
    await tester.tap(find.widgetWithText(TextButton, '下载'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('下载分离模型'), findsOneWidget);
    expect(find.text('人声分离'), findsOneWidget);
    expect(find.text('去和声'), findsOneWidget);
    expect(find.textContaining('Ultimate Vocal Remover'), findsOneWidget);
    // Where the files come from and how they are checked is not the user's
    // concern.
    expect(find.textContaining('hf-mirror'), findsNothing);
    expect(find.textContaining('SHA-256'), findsNothing);
    await screenshot(tester, '7_model_download');
  });

  testWidgets('settings measure, retry and cancel before saving only the current route', (tester) async {
    phone(tester);
    const result = LatencyCalibrationReading(
      route: OutputRoute.bluetooth,
      measurement: false,
      totalSeconds: 0.186,
      systemSeconds: 0.142,
    );
    const longResult = LatencyCalibrationReading(
      route: OutputRoute.bluetooth,
      measurement: false,
      totalSeconds: 0.657,
      systemSeconds: 0.142,
    );
    final measurer = _FakeLatencyMeasurer(OutputRoute.bluetooth, [result, longResult, longResult]);
    final settings = AppSettings(null)..latencyOffsetMs = 25;
    final app = AppServices(settings: settings, songs: services.songs, models: services.models, latencyMeasurer: measurer);
    await tester.pumpWidget(host(app, const SettingsPage()));
    final entry = find.widgetWithText(ListTile, '测量延迟');
    await tester.scrollUntilVisible(entry, 200);
    expect(find.text('当前线路：蓝牙耳机'), findsOneWidget);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    expect(find.text('自动测'), findsOneWidget);
    expect(find.text('跟拍测'), findsOneWidget);
    await tester.tap(find.text('自动测'));
    await tester.tap(find.text('开始测量'));
    await tester.pumpAndSettle();
    expect(find.textContaining('测得总延迟 186 ms（系统报告 142 ms）'), findsOneWidget);
    expect(find.textContaining('设为 +44 ms'), findsOneWidget);
    expect(settings.latencyOffsetFor(OutputRoute.bluetooth, measurement: false), 25);
    await tester.tap(find.text('再测一次'));
    await tester.pumpAndSettle();
    expect(find.textContaining('设为 +515 ms'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(settings.latencyOffsetFor(OutputRoute.bluetooth, measurement: false), 25);

    await tester.tap(entry);
    await tester.pumpAndSettle();
    await tester.tap(find.text('开始测量'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('使用'));
    await tester.pumpAndSettle();
    expect(find.byType(AlertDialog), findsNothing);
    expect(measurer.calls, [
      (LatencyCalibrationMethod.automatic, false),
      (LatencyCalibrationMethod.automatic, false),
      (LatencyCalibrationMethod.tapAlong, false),
    ]);
    expect(settings.latencyOffsetFor(OutputRoute.bluetooth, measurement: false), 515);
    final slider = find.descendant(of: find.byType(LatencyCompensationSlider), matching: find.byType(Slider));
    expect(tester.widget<Slider>(slider).value, 515);
    expect(tester.widget<Slider>(slider).max, greaterThanOrEqualTo(515));

    measurer.outputRoute = OutputRoute.speaker;
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.text('当前线路：外放'), findsOneWidget);
    expect(tester.widget<Slider>(slider).value, 25);
    tester.widget<Slider>(slider).onChanged!(-40);
    await tester.pump();
    expect(settings.latencyOffsetFor(OutputRoute.speaker, measurement: false), -40);
    expect(settings.latencyOffsetFor(OutputRoute.bluetooth, measurement: false), 515);
    expect(settings.latencyOffsetMs, 25);
  });

  testWidgets('about page credits the models and opens the licenses', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const AboutPage()));
    await tester.pump();
    expect(find.text('检查更新'), findsOneWidget);
    expect(find.text('还没有检查过'), findsOneWidget);
    expect(find.textContaining('github.com/zhikkz/YinTrace'), findsOneWidget);
    await screenshot(tester, '8_about');
    final scrollable = find.byType(Scrollable).first;
    await tester.scrollUntilVisible(find.textContaining('Anjok07 和 aufr33'), 300, scrollable: scrollable);
    expect(find.textContaining('hf-mirror'), findsNothing);
    // Further down the app states its own license and where the source is.
    await tester.scrollUntilVisible(find.text('许可全文与开源组件'), 300, scrollable: scrollable);
    expect(find.textContaining('AGPL-3.0'), findsWidgets);
    expect(find.text('第三方声明'), findsOneWidget);
    await tester.tap(find.text('许可全文与开源组件'));
    await tester.pumpAndSettle();
    expect(find.text('音迹'), findsWidgets);
  });

  LatestRelease release(String tag) => LatestRelease.fromJson({
    'tag_name': tag,
    'html_url': '$appSourceUrl/releases/tag/$tag',
    'name': '',
    'published_at': '2026-12-01T08:00:00Z',
  });

  testWidgets('about page checks on request, shows a newer version with a dot and opens or copies links', (
    tester,
  ) async {
    phone(tester);
    final opened = <Uri>[];
    var canOpen = true;
    String? copied;
    tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') copied = (call.arguments as Map)['text'] as String?;
      return null;
    });
    addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
    var fetches = 0;
    final updates = UpdateChecker(fetch: () async {
      fetches++;
      return release('v9.9.0');
    });
    final app = AppServices(settings: AppSettings(null), songs: services.songs, models: services.models, updates: updates);
    await tester.pumpWidget(host(app, AboutPage(openUrl: (url) async {
      opened.add(url);
      return canOpen;
    })));
    await tester.pump();
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump();
    expect(fetches, 1);
    expect(find.text('有新版本 9.9.0'), findsOneWidget);
    expect(find.textContaining('2026 年 12 月 1 日发布 · 前往下载页'), findsOneWidget);
    expect(find.byKey(const ValueKey('update-dot')), findsOneWidget);
    // Only the dot: no dialog, no snack bar.
    expect(find.byType(Dialog), findsNothing);
    expect(find.byType(SnackBar), findsNothing);
    // Found while the page is open, it is already seen.
    expect(updates.hasUnseenUpdate, isFalse);
    await screenshot(tester, '8b_about_update');

    await tester.tap(find.text('有新版本 9.9.0'));
    await tester.pump();
    expect(opened.last, Uri.parse('$appSourceUrl/releases/tag/v9.9.0'));
    await tester.tap(find.text('GitHub 仓库'));
    await tester.pump();
    expect(opened.last, Uri.parse(appSourceUrl));
    await tester.tap(find.byTooltip('复制仓库地址'));
    await tester.pump();
    expect(copied, appSourceUrl);
    expect(find.text('已复制到剪贴板'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
    expect(find.text('github.com/zhikkz/YinTrace'), findsOneWidget);
    // Without a browser the address is copied instead.
    canOpen = false;
    copied = null;
    await tester.tap(find.text('有新版本 9.9.0'));
    await tester.pump();
    await tester.pump();
    expect(copied, '$appSourceUrl/releases/tag/v9.9.0');
    expect(find.text('打不开浏览器，已复制地址'), findsOneWidget);
    await tester.pump(const Duration(seconds: 4));
  });

  testWidgets('turning automatic checks on checks, and a check asked for says why it failed', (tester) async {
    phone(tester);
    final answers = <Future<LatestRelease?> Function()>[
      () async => null,
      () async => throw UpdateCheckException('连不上 GitHub'),
    ];
    var fetches = 0;
    final updates = UpdateChecker(fetch: () {
      fetches++;
      return answers.removeAt(0)();
    });
    final settings = AppSettings(null);
    final app = AppServices(settings: settings, songs: services.songs, models: services.models, updates: updates);
    await tester.pumpWidget(host(app, const AboutPage()));
    await tester.pump();
    final toggle = find.widgetWithText(SwitchListTile, '自动检查更新');
    expect(tester.widget<SwitchListTile>(toggle).value, isTrue);
    await tester.tap(toggle);
    await tester.pump();
    expect(settings.autoCheckUpdates, isFalse);
    expect(fetches, 0);
    await tester.tap(toggle);
    await tester.pump();
    await tester.pump();
    expect(settings.autoCheckUpdates, isTrue);
    // Never answered before: the automatic check asks right away. No
    // release published yet is no news.
    expect(fetches, 1);
    expect(find.textContaining('已是最新版本 · 今天'), findsOneWidget);

    await tester.tap(find.text('检查更新'));
    await tester.pump();
    await tester.pump();
    expect(fetches, 2);
    expect(find.text('没能检查：连不上 GitHub'), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);
    expect(find.byKey(const ValueKey('update-dot')), findsNothing);
  });

  testWidgets('a newer version is a red dot on the settings button and in settings until About is opened', (
    tester,
  ) async {
    phone(tester);
    final updates = UpdateChecker(fetch: () async => release('v9.9.0'));
    await updates.check();
    final app = AppServices(
      settings: AppSettings(null),
      songs: services.songs,
      models: services.models,
      latencyMeasurer: _FakeLatencyMeasurer(OutputRoute.speaker, []),
      updates: updates,
    );
    await tester.pumpWidget(host(app, const LibraryPage()));
    await settleIo(tester);
    expect(find.byTooltip('设置，有新版本'), findsOneWidget);
    expect(tester.widget<Badge>(find.ancestor(of: find.byIcon(Icons.settings_outlined), matching: find.byType(Badge))).isLabelVisible,
        isTrue);
    await screenshot(tester, '1b_library_update_dot');

    await tester.tap(find.byTooltip('设置，有新版本'));
    await tester.pumpAndSettle();
    final about = find.widgetWithText(ListTile, '关于音迹');
    await tester.scrollUntilVisible(about, 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('有新版本 9.9.0'), findsOneWidget);
    expect(find.descendant(of: about, matching: find.byKey(const ValueKey('update-dot'))), findsOneWidget);
    expect(find.byType(Dialog), findsNothing);

    await tester.tap(about);
    await tester.pumpAndSettle();
    expect(find.text('有新版本 9.9.0'), findsOneWidget);
    expect(updates.hasUnseenUpdate, isFalse);
    await tester.pageBack();
    await tester.pumpAndSettle();
    // Still says there is one, without the dot.
    expect(find.text('有新版本 9.9.0'), findsOneWidget);
    expect(find.descendant(of: about, matching: find.byKey(const ValueKey('update-dot'))), findsNothing);
    await tester.pageBack();
    await settleIo(tester);
    expect(find.byTooltip('设置'), findsOneWidget);
    expect(find.byTooltip('设置，有新版本'), findsNothing);
  });

  testWidgets('benchmark page (test builds) shows the last report', (tester) async {
    phone(tester);
    final file = File('${tmp.path}/benchmark/last-report.json')
      ..createSync(recursive: true)
      ..writeAsStringSync(jsonEncode(sampleReport()));
    await tester.runAsync(() async {
      await tester.pumpWidget(host(services, BenchmarkPage(storeFile: file)));
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    expect(find.text('上次的测试已完成'), findsOneWidget);
    expect(find.text('复制报告'), findsOneWidget);
    await screenshot(tester, '9_benchmark');
    // Further down: how to run it again.
    await tester.scrollUntilVisible(find.text('重新测试'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.text('4 分钟'), findsOneWidget);
    await screenshot(tester, '9b_benchmark_start');
  });

  /// Opens the scores the way the singer does; the sheet comes up once the
  /// run is saved, which takes a while on a busy machine.
  Future<void> openScores(WidgetTester tester) async {
    await tester.tap(find.byTooltip('查看评分'));
    for (var i = 0; i < 80 && find.byType(ResultsSheet).evaluate().isEmpty; i++) {
      await settleIo(tester, rounds: 2);
    }
    expect(find.byType(ResultsSheet), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 600)); // the sheet's entrance
  }

  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];

  testWidgets('the practice entry pauses the song, shows failures and applies the confirmed offset', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final measurer = _FakeLatencyMeasurer(OutputRoute.wired, [
      LatencyCalibrationFailure.noTestSound,
      LatencyCalibrationFailure.routeChanged,
      const LatencyCalibrationReading(
        route: OutputRoute.wired,
        measurement: true,
        totalSeconds: 0.094,
        systemSeconds: 0.060,
      ),
    ]);
    final settings = AppSettings(null);
    final app = AppServices(settings: settings, songs: services.songs, models: services.models, latencyMeasurer: measurer);
    late PracticeSession session;
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpWidget(
      host(
        app,
        PracticePage(
          meta: song,
          reference: ref,
          sessionFactory: (_) => session = PracticeSession(
            meta: song,
            reference: ref,
            repository: app.songs,
            settings: settings,
            engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
            readOutputRoute: () => measurer.outputRoute,
            decodeInBackground: false,
          ),
          backgroundWork: false,
        ),
      ),
    );
    await tester.pump();
    expect(session.started, isTrue);
    session.setMonitorEnabled(true);
    session.play();
    final engine = session.engine!;
    engine.render(512, input: Float32List(512));
    final position = engine.positionFrame;
    var playingDuringMeasurement = true;
    var capturingDuringMeasurement = true;
    measurer.onMeasure = () {
      playingDuringMeasurement = session.isPlaying;
      engine.render(512, input: Float32List(512));
      capturingDuringMeasurement = engine.readCapture().isNotEmpty;
    };
    await tester.tap(find.byTooltip('练习设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final entry = find.widgetWithText(TextButton, '测量延迟');
    await tester.ensureVisible(entry);
    await tester.pump();
    expect(find.text('当前线路：有线耳机（测量模式）'), findsOneWidget);
    await tester.tap(entry);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('自动测'));
    await tester.tap(find.text('开始测量'));
    await tester.pump();
    expect(playingDuringMeasurement, isFalse);
    expect(capturingDuringMeasurement, isFalse);
    expect(find.textContaining('没听到测试音'), findsOneWidget);
    expect(find.textContaining('测得总延迟'), findsNothing);
    expect(find.text('使用'), findsNothing);
    await tester.tap(find.text('再测一次'));
    await tester.pump();
    expect(find.textContaining('音频线路变了'), findsOneWidget);
    expect(settings.latencyOffsetFor(OutputRoute.wired, measurement: true), 0);

    await tester.tap(find.text('再测一次'));
    await tester.pump();
    expect(find.textContaining('设为 +34 ms'), findsOneWidget);
    expect(settings.latencyOffsetFor(OutputRoute.wired, measurement: true), 0);
    await tester.tap(find.text('使用'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(session.isPlaying, isFalse);
    expect(session.monitorEnabled, isTrue);
    expect(engine.positionFrame, position);
    expect(settings.latencyOffsetFor(OutputRoute.wired, measurement: true), 34);
    expect(session.latency - session.systemLatency, closeTo(0.034, 1e-9));
    expect(find.text('+34 ms'), findsOneWidget);
    expect(measurer.calls, [
      (LatencyCalibrationMethod.automatic, true),
      (LatencyCalibrationMethod.automatic, true),
      (LatencyCalibrationMethod.automatic, true),
    ]);
  }, skip: lib == null || lib.isEmpty);

  testWidgets('free practice monitors the mic without tracks and disarms when headphones are lost', (tester) async {
    phone(tester);
    final settings = AppSettings(null);
    final tunerServices = AppServices(settings: settings, songs: services.songs, models: services.models);
    late PracticeEngine engine;
    await tester.pumpWidget(
      host(tunerServices, TunerPage(engineFactory: () => engine = PracticeEngine.create(mode: EngineMode.offline))),
    );
    await tester.pump();
    // The monitor high-passes the mic: sing a tone (whole periods per
    // callback) and measure the settled RMS of what both ears hear.
    final mic = Float32List.fromList([for (var i = 0; i < 256; i++) 0.05 * math.sin(2 * math.pi * i / 128)]);
    double heard() {
      var out = Float32List(0);
      var peak = 0.0;
      for (var i = 0; i < 8; i++) {
        out = engine.render(mic.length, input: mic);
        for (final v in out) {
          peak = math.max(peak, v.abs());
        }
      }
      var sum = 0.0;
      for (var i = 0; i < out.length; i += 2) {
        expect(out[i + 1], out[i]);
        sum += out[i] * out[i];
      }
      // Silent means silent from the very first callback, not a late mute.
      if (sum == 0) expect(peak, 0, reason: 'the monitor must be muted at once');
      return math.sqrt(sum / mic.length);
    }

    expect(engine.isPlaying, isFalse);
    expect(heard(), 0);

    await tester.tap(find.byTooltip('耳返设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final monitor = find.widgetWithText(SwitchListTile, '耳返（有线耳机）');
    expect(tester.widget<SwitchListTile>(monitor).value, isFalse);
    await tester.tap(monitor);
    await tester.pump();
    expect(settings.monitorLevel, 0.5);
    final atHalf = heard();
    expect(atHalf, greaterThan(0.05)); // +12 dB on a compressed -29 dBFS tone
    expect(engine.readCapture().last.samples, mic); // recorded dry

    await tester.tapAt(tester.getCenter(find.byType(Slider)) + const Offset(60, 0));
    await tester.pump();
    expect(settings.monitorLevel, greaterThan(0.5));
    final louder = heard();
    expect(louder / atHalf, closeTo(settings.monitorGain / 4, 1e-3));

    engine.signalAudioEvent(AudioEvents.routeChanged);
    expect(heard(), 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(heard(), closeTo(louder, louder * 1e-3));

    engine.signalAudioEvent(AudioEvents.deviceLost);
    expect(heard(), 0);
    await tester.pump(const Duration(milliseconds: 16));
    expect(tester.widget<SwitchListTile>(monitor).value, isFalse);
    Navigator.of(tester.element(monitor)).pop();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.text('继续练习'));
    await tester.pump();
    expect(heard(), 0);
    expect(engine.readCapture().last.samples, mic);
  }, skip: lib == null);
  testWidgets('scores hide line playback when the scored line has no recording', (tester) async {
    phone(tester);
    final reference = SongReference(
      duration: 10,
      lines: [
        RefLine(
          index: 0,
          text: '中',
          lrcStart: 5,
          tokens: [RefToken(text: '中', start: 5, end: 6, notes: [RefNote(start: 5, end: 6, midi: 60)])],
        ),
      ],
    );
    late PracticeSession session;
    await tester.pumpWidget(
      host(
        services,
        PracticePage(
          meta: song,
          reference: reference,
          sessionFactory: (_) => session = PracticeSession(
            meta: song,
            reference: reference,
            repository: services.songs,
            settings: AppSettings(null),
            engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
            decodeInBackground: false,
          ),
        ),
      ),
    );
    await settleIo(tester);

    final take = session.take!;
    final clip = Float32List(256)..fillRange(0, 256, 0.25);
    take.addAudio(clip, sr, 0);
    take.addAudio(clip, 9 * sr, 0);
    // Mark the line as attempted without adding PCM or a sung run to history.
    for (var i = 500; i < 600; i++) {
      final t = i / 100;
      session.scorer.add(LivePitch(songTime: t, clockTime: t, midi: 0, levelDb: -100, playing: true, aperiodicity: 1));
    }

    await openScores(tester);
    expect(find.text('回听这一遍'), findsOneWidget);
    await tester.scrollUntilVisible(find.byTooltip('听原唱这一句'), 160);
    expect(find.byTooltip('回听这一句'), findsNothing);

    take.addAudio(clip, 4 * sr, 0); // playback lead-in, outside this line's recording span
    expect(session.canListenBack(line: 0), isFalse);
    take.addAudio(Float32List(256), 5 * sr, 0);
    expect(session.canListenBack(line: 0), isTrue);
  }, skip: lib == null);

  testWidgets('practice page scores a singer through the native engine', (tester) async {
    phone(tester);
    final ref = await tester.runAsync(() => services.songs.loadReference(song.id));
    final contour = await tester.runAsync(() => services.songs.loadPitchTrack(song.id));
    late PracticeSession session;
    await tester.pumpWidget(
      host(
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
          exportPageBuilder: (songId, id) => Scaffold(body: Text('成品 $id')),
          backgroundWork: false,
        ),
      ),
    );
    // Return to the foreground while the background decode may still be
    // pending. Loading completion must keep the microphone stopped.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await settleIo(tester, rounds: 5);
    expect(session.error, isNull);
    expect(session.started, isTrue);
    // The practice settings expose wired monitoring, initially off.
    await tester.tap(find.byTooltip('练习设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final monitorSwitch = find.widgetWithText(SwitchListTile, '耳返（有线耳机）');
    await tester.ensureVisible(monitorSwitch);
    await tester.pump();
    expect(tester.widget<SwitchListTile>(monitorSwitch).value, isFalse);
    await tester.tap(monitorSwitch);
    await tester.pump();
    expect(session.monitorEnabled, isTrue);
    expect(find.text('耳返音量'), findsOneWidget);
    await tester.tap(find.byType(CloseButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    session.engine!.render(512, input: Float32List(512));
    expect(session.engine!.readCapture(), isEmpty);
    session.play();
    final engine = session.engine!;
    // The native device must stop both playback and capture on backgrounding.
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    await tester.pump();
    final heldPosition = engine.positionFrame;
    expect(session.isPlaying, isFalse);
    engine.render(512, input: Float32List(512));
    expect(engine.positionFrame, heldPosition);
    expect(engine.readCapture(), isEmpty);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pump();
    expect(session.isPlaying, isFalse); // user resumes deliberately
    session.play();
    // iOS announces route changes when playback and recording start (the
    // category applied, the route reconfigured): practice goes on.
    engine.signalAudioEvent(AudioEvents.routeChanged);
    session.tick();
    expect(session.isPlaying, isTrue);
    expect(session.pauseReason, isNull);
    final before = engine.positionFrame;
    engine.render(512, input: Float32List(512));
    expect(engine.positionFrame, before + 512);
    engine.signalAudioEvent(AudioEvents.stopped); // a phone call
    session.tick();
    expect(session.isPlaying, isFalse);
    expect(session.pauseReason, contains('打断'));
    engine.render(512, input: Float32List(512));
    expect(engine.readCapture(), isEmpty);
    engine.signalAudioEvent(AudioEvents.interruptionEnded); // call ends; still paused
    session.tick();
    expect(session.isPlaying, isFalse);
    session.play();
    expect(session.isPlaying, isTrue);
    expect(session.pauseReason, isNull);
    // Headphones unplugged: paused at once, so nothing plays from the speaker.
    engine.signalAudioEvent(AudioEvents.routeChanged | AudioEvents.deviceLost);
    expect(session.isPlaying, isFalse);
    session.tick();
    expect(session.pauseReason, contains('耳机'));
    session.play();
    expect(session.isPlaying, isTrue);
    // Render the song in 512 frame blocks with the singer as mic input,
    // pumping frames so the page's ticker pulls and scores the capture.
    Future<void> runUntil(double seconds, {Float32List? voice}) async {
      final samples = voice ?? singer;
      while (engine.positionSeconds < seconds) {
        final pos = engine.positionFrame;
        final n = 512;
        final input = Float32List(n);
        for (var i = 0; i < n && pos + i < samples.length; i++) {
          input[i] = samples[pos + i];
        }
        engine.render(n, input: input);
        await tester.pump(const Duration(milliseconds: 11));
      }
    }

    final graphFinder = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter);
    PitchGraphPainter graph() => tester.widget<CustomPaint>(graphFinder).painter! as PitchGraphPainter;

    void expectMarkerAt(UserPoint point, String reason) {
      expect(point.midi, greaterThan(0), reason: reason);
      final g = graph();
      final size = tester.getSize(graphFinder);
      final x = g.gutter + (point.time - g.t0) / (g.t1 - g.t0) * (size.width - g.gutter);
      final y = size.height - (point.midi - g.midiLo) / (g.midiHi - g.midiLo) * size.height;
      expect(
        graphFinder,
        paints..something((method, args) => method == #drawCircle && args[0] == Offset(x, y) && args[1] == 4.5),
        reason: reason,
      );
    }

    void expectNoMarker(String reason) {
      // The marker has a core and a halo. The smaller trace dots may remain.
      expect(
        graphFinder,
        paints..everything((method, args) => method != #drawCircle || (args[1] != 4.5 && args[1] != 9)),
        reason: reason,
      );
    }

    // A low voice in the lead-in must be visible alongside the upcoming
    // original melody, even outside the original singer's pitch range.
    final lowVoice = synthVoice([const Syl(0.1, 0.6, 48, unvoicedOnset: false)], 0.6);
    await runUntil(0.08, voice: lowVoice);
    final initialFloor = graph().midiLo;
    await runUntil(0.22, voice: lowVoice);
    final expandingFloor = graph().midiLo;
    await runUntil(0.5, voice: lowVoice);
    final liveGraph = graph();
    final sungPitch = liveGraph.user.last;
    expect(expandingFloor, lessThan(initialFloor));
    expect(expandingFloor, greaterThan(liveGraph.midiLo), reason: 'the axis expands over several frames');
    expect(sungPitch.midi, closeTo(48, 0.5));
    expect(liveGraph.midiLo, lessThan(sungPitch.midi));
    final originalPitch = ref.lines.first.notes.first.midi;
    expect(liveGraph.midiHi, greaterThan(originalPitch));
    expect(liveGraph.playhead! - sungPitch.time, closeTo(0, 0.1));
    expect(liveGraph.live, isTrue);
    session.pause();
    await tester.pump();
    expect(graph().live, isFalse);
    session.play();

    await runUntil(2.7);
    expect(graph().t0, greaterThan(sungPitch.time));
    expect(graph().midiLo, lessThan(sungPitch.midi), reason: 'short gaps keep the recent low range');
    await runUntil(6.4);
    final contractingFloor = graph().midiLo;
    expect(contractingFloor, greaterThan(liveGraph.midiLo));
    await runUntil(6.75);
    expect(graph().midiLo, greaterThan(contractingFloor), reason: 'the axis also contracts over several frames');

    await runUntil(7.9);
    expect(find.textContaining('记得带伞'), findsWidgets);
    await screenshot(tester, '3_practice');
    final returnPosition = engine.positionSeconds;
    session.listenBack();
    Future<void> advanceReview(double seconds) async {
      engine.render((seconds * sr).round());
      await tester.pump(const Duration(milliseconds: 16));
      expect(session.listening, ListenKind.take);
      expect(session.isPlaying, isTrue);
    }

    await advanceReview(0.35); // 0.35 s: the low voice recorded in the lead-in
    final held = session.reviewPoint!;
    expectMarkerAt(held, 'voiced take before pause');
    await tester.tap(find.byIcon(Icons.pause_rounded));
    await tester.pump();
    expect(session.isPlaying, isFalse);
    expect(session.reviewPoint?.time, held.time);
    expectNoMarker('paused on a voiced take sample');
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(session.isPlaying, isTrue);
    expectMarkerAt(held, 'resuming at the same voiced sample');

    await advanceReview(0.5); // 0.85 s: between the low voice and the first lyric
    expect(session.reviewPoint?.midi, 0);
    expectNoMarker('playing an unvoiced sample');
    await advanceReview(0.5); // 1.35 s: inside the first sung lyric
    final recovered = session.reviewPoint!;
    expect(recovered.time, greaterThan(held.time));
    expectMarkerAt(recovered, 'the first lyric after the gap');
    session.seek(session.take!.endSeconds + 0.15); // still inside the review tail
    await tester.pump();
    expect(session.isPlaying, isTrue);
    expect(session.reviewPoint, isNull);
    expectNoMarker('playing beyond the last recorded sample');

    await tester.tap(find.text('回到练习'));
    await tester.pump();
    expect(session.reviewing, isFalse);
    expectNoMarker('back in practice before the singer resumes');
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(session.isPlaying, isTrue);
    await runUntil(8.33); // the next syllable after returning to practice
    expect(graph().playbackPoint, isNull);
    expect(session.points.last.time, greaterThan(returnPosition));
    expectMarkerAt(session.points.last, 'normal practice marks the new microphone sample');

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

    await openScores(tester);
    expect(find.text('先练这几个字'), findsOneWidget);
    await screenshot(tester, '4_results');
    final history = await tester.runAsync(() => services.songs.loadHistory(song.id));
    expect(history!.length, 3);

    // Listen back: the take plays where it was sung, the original singer is
    // muted (the accompaniment here is silence) and nothing gets scored.
    expect(find.byTooltip('回听这一句'), findsWidgets);
    final practisedTo = engine.positionSeconds;
    await tester.tap(find.text('回听这一遍'));
    await settleIo(tester, rounds: 10);
    await tester.pump(const Duration(milliseconds: 300)); // the sheet's exit
    expect(session.reviewing, isTrue);
    expect(session.isPlaying, isTrue);
    expect(find.text('回到练习'), findsOneWidget);
    final scored = session.scorer.overallScore();
    session.seek(ref.lines.first.start + 0.4); // into the singing
    final from = engine.positionFrame;
    final heard = engine.render(4096);
    var err = 0.0, level = 0.0;
    for (var i = 0; i < 4096; i++) {
      final sung = from + i < singer.length ? singer[from + i] : 0.0;
      err = math.max(err, (heard[2 * i] - sung).abs());
      level = math.max(level, sung.abs());
    }
    expect(level, greaterThan(0.01), reason: 'the listened span has singing');
    expect(err, lessThan(1e-3), reason: 'played back exactly what was captured');
    await tester.pump(const Duration(milliseconds: 16));
    expect(session.scorer.overallScore(), scored);
    final reviewGraph = graph();
    final playedPoint = session.reviewPoint!;
    expect(reviewGraph.user.any((p) => p.midi > 0 && p.time > playedPoint.time + 0.5 && p.time < reviewGraph.t1), isTrue);
    expectMarkerAt(playedPoint, 'the playback dot marks the sample at the playhead even with later samples on screen');
    await screenshot(tester, '4b_listen_back');
    await tester.tap(find.text('回到练习'));
    await tester.pump();
    expect(session.reviewing, isFalse);
    expect(find.text('回到练习'), findsNothing);
    expect(engine.positionSeconds, closeTo(practisedTo, 0.02), reason: 'practice continues where it was');

    // How does the line go? The original singer at full volume, nothing
    // scored; afterwards practice waits at the start of that line.
    final linesBefore = [for (final r in session.scorer.results()) r.score];
    await tester.tap(find.text('听这句原唱'));
    await tester.pump();
    expect(session.listening, ListenKind.original);
    expect(find.text('正在听原唱，听完回到这一句开头'), findsOneWidget);
    expect(graph().user, isEmpty);
    final heardLine = ref.lines[session.originalLine!];
    session.seek(heardLine.start + 0.2);
    final vocalTrack = readWavFile(services.songs.pathFor(song.id, song.vocalsFile)).samples;
    final at = engine.positionFrame;
    final original = engine.render(2048);
    var diff = 0.0, loud = 0.0;
    for (var i = 0; i < 2048; i++) {
      diff = math.max(diff, (original[2 * i] - vocalTrack[at + i]).abs());
      loud = math.max(loud, vocalTrack[at + i].abs());
    }
    expect(loud, greaterThan(0.01));
    expect(diff, lessThan(1e-3), reason: 'the original vocal, unattenuated');
    await screenshot(tester, '4c_listen_original');
    for (var i = 0; i < 400 && session.reviewing; i++) {
      engine.render(512, input: Float32List(512));
      await tester.pump(const Duration(milliseconds: 11));
    }
    expect(session.reviewing, isFalse);
    expect(session.isPlaying, isFalse);
    expect(engine.positionSeconds, closeTo(math.max(0, heardLine.start - 1.0), 0.02));
    // Nothing was scored while the original played: every line keeps its
    // score, the line heard too, until it is sung again.
    final after = session.scorer.results();
    expect([for (final r in after) r.score], linesBefore);

    // Keep the take and make a finished track of it. Looking at the scores
    // again does not store the same run a second time.
    await openScores(tester);
    expect((await tester.runAsync(() => services.songs.loadHistory(song.id)))!.length, 3);
    expect((await tester.runAsync(() => services.songs.load(song.id)))!.practiceCount, 3);
    await tester.ensureVisible(find.text('制作成品'));
    await tester.pump();
    await tester.tap(find.text('制作成品'));
    await settleIo(tester, rounds: 20);
    final kept = (await tester.runAsync(() => services.songs.loadRecordings(song.id)))!;
    expect(find.text('成品 ${kept.first.id}'), findsOneWidget);
    expect(kept.first.start, closeTo(math.max(0, session.take!.startSeconds - 0.2), 0.01));
    expect(session.isPlaying, isFalse);

    // Back from 制作成品: a character to work on opens its line's loop.
    Navigator.of(tester.element(find.text('成品 ${kept.first.id}'))).pop();
    await settleIo(tester, rounds: 5);
    await tester.pump(const Duration(milliseconds: 600)); // the page's exit
    await openScores(tester);
    final tile = find.descendant(of: find.byType(BottomSheet), matching: find.text('记'));
    await tester.ensureVisible(tile);
    await tester.pump();
    await tester.tap(tile);
    await settleIo(tester, rounds: 5);
    await tester.pump(const Duration(milliseconds: 300)); // the sheet's exit
    expect(session.loopLine, 1, reason: '记 is in the second line');
    expect(session.currentLine, 1);
    // Paused in the loop's lead-in: the looped line is shown, with a way out.
    expect(find.text('单句循环 · 第 2 / 2 句'), findsOneWidget);
    expect(find.text('退出循环'), findsOneWidget);
    await screenshot(tester, '3b_practice_loop');
    // The run ended as the loop began. Store it while the page is still
    // here, so that the save on disposal has nothing left to write: a save
    // still running when the test ends never finishes, and this song's reads
    // and writes in the next tests would wait for it.
    var stored = false;
    session.save().then((_) => stored = true);
    for (var i = 0; i < 60 && !stored; i++) {
      await settleIo(tester, rounds: 1);
    }
    expect(stored, isTrue);
    // Dispose the page (and with it the native engine).
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);

  /// A page that opens the practice page for [song] with the offline
  /// engine; the session ends up in [onSession], the save on leaving in
  /// [onLeave].
  Widget practiceLauncher(
    SongReference ref, {
    required void Function(PracticeSession) onSession,
    required void Function(Future<void>) onLeave,
  }) => host(
    services,
    Builder(
      builder: (context) => Scaffold(
        body: TextButton(
          onPressed: () => Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => PracticePage(
                meta: song,
                reference: ref,
                onLeave: onLeave,
                sessionFactory: (_) {
                  final s = PracticeSession(
                    meta: song,
                    reference: ref,
                    repository: services.songs,
                    settings: services.settings,
                    engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
                  );
                  onSession(s);
                  return s;
                },
                backgroundWork: false,
              ),
            ),
          ),
          child: const Text('练习'),
        ),
      ),
    ),
  );

  testWidgets('practice settings can be closed after scrolling while the song plays', (tester) async {
    phone(tester);
    tester.view.physicalSize = const Size(390 * 3, 600 * 3);
    tester.view.padding = const FakeViewPadding(top: 48 * 3, bottom: 34 * 3);
    final ref = await tester.runAsync(() => services.songs.loadReference(song.id));
    late PracticeSession session;
    var leftPractice = false;
    await tester.pumpWidget(
      practiceLauncher(ref!, onSession: (s) => session = s, onLeave: (_) => leftPractice = true),
    );
    await tester.tap(find.text('练习'));
    await settleIo(tester);
    await tester.tap(find.byIcon(Icons.play_arrow_rounded));
    await tester.pump();
    expect(session.isPlaying, isTrue);

    await tester.tap(find.byTooltip('练习设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    final close = find.byType(CloseButton);
    expect(close.hitTestable(), findsOneWidget);
    final closePosition = tester.getTopLeft(close);
    expect(closePosition.dy, greaterThanOrEqualTo(48));
    final lastSetting = find.text('忽略八度');
    expect(lastSetting.hitTestable(), findsNothing);
    await tester.ensureVisible(lastSetting);
    await tester.pump();
    expect(lastSetting.hitTestable(), findsOneWidget);
    expect(tester.getTopLeft(close), closePosition);

    await tester.tap(close);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.byType(BottomSheet), findsNothing);
    expect(find.byIcon(Icons.pause_rounded).hitTestable(), findsOneWidget);
    expect(session.isPlaying, isTrue);
    expect(leftPractice, isFalse);
  }, skip: lib == null || lib.isEmpty);

  /// Plays the song up to [seconds] with the singer at the microphone.
  Future<void> singUntil(WidgetTester tester, PracticeSession session, double seconds) async {
    final engine = session.engine!;
    while (engine.positionSeconds < seconds && engine.isPlaying) {
      final pos = engine.positionFrame;
      final input = Float32List(512);
      for (var i = 0; i < 512 && pos + i < singer.length; i++) {
        input[i] = singer[pos + i];
      }
      engine.render(512, input: input);
      await tester.pump(const Duration(milliseconds: 11));
    }
  }

  testWidgets('dragging the practice pitch graph seeks at the graph scale', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    late PracticeSession session;
    await tester.pumpWidget(practiceLauncher(ref, onSession: (s) => session = s, onLeave: (_) {}));
    await tester.tap(find.text('练习'));
    await settleIo(tester);
    expect(session.started, isTrue);

    final graph = find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter);
    final painter = tester.widget<CustomPaint>(graph).painter! as PitchGraphPainter;
    final secondsPerPixel = (painter.t1 - painter.t0) / (tester.getSize(graph).width - painter.gutter);
    final engine = session.engine!;
    session.seek(3);
    await tester.pump();

    await tester.tap(graph);
    await tester.drag(graph, const Offset(0, 80));
    expect(engine.positionSeconds, closeTo(3, 0.001));

    final gesture = await tester.startGesture(tester.getCenter(graph));
    await gesture.moveBy(const Offset(-60, 0));
    expect(session.position, closeTo(3 + 60 * secondsPerPixel, 0.001));
    expect(engine.positionSeconds, closeTo(3, 0.001));
    await tester.pump(); // the moving chart must keep the same drag anchor
    await gesture.moveBy(const Offset(-40, 0));
    expect(session.position, closeTo(3 + 100 * secondsPerPixel, 0.001));
    await gesture.up();
    expect(engine.positionSeconds, closeTo(3 + 100 * secondsPerPixel, 0.001));
    expect(session.isPlaying, isFalse);

    session.play();
    session.setMonitorEnabled(true);
    await tester.pump();
    final mic = Float32List(64)..fillRange(0, 64, 0.4);
    final playingDrag = await tester.startGesture(tester.getCenter(graph));
    await playingDrag.moveBy(const Offset(80, 0));
    expect(session.isPlaying, isTrue);
    expect(engine.render(64, input: mic), everyElement(0));
    await playingDrag.up();
    expect(engine.positionSeconds, closeTo(3 + 20 * secondsPerPixel, 0.001));
    expect(session.isPlaying, isTrue);
    expect(engine.render(64, input: mic), anyElement(isNot(0)));

    session.seek(0.3);
    final atStart = await tester.startGesture(tester.getCenter(graph));
    await atStart.moveBy(const Offset(80, 0));
    expect(session.position, 0);
    await atStart.moveBy(const Offset(-60, 0));
    expect(session.position, closeTo(60 * secondsPerPixel, 0.001));
    await atStart.up();

    await tester.drag(graph, const Offset(-1000, 0));
    expect(engine.positionSeconds, closeTo(session.duration, 0.001));
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);

  testWidgets('the practice timeline is silent while dragging and resumes on release or cancel', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    late PracticeSession session;
    await tester.pumpWidget(practiceLauncher(ref, onSession: (s) => session = s, onLeave: (_) {}));
    await tester.tap(find.text('练习'));
    await settleIo(tester);
    final engine = session.engine!;
    session.seek(2);
    session.play();
    session.setMonitorEnabled(true);
    await tester.pump();

    final timeline = find.byKey(const ValueKey('practice-timeline'));
    final bounds = tester.getRect(timeline);
    final start = bounds.center;
    final mic = Float32List(64)..fillRange(0, 64, 0.4);
    final before = engine.positionFrame;
    final canceled = await tester.startGesture(start);
    await tester.pump(const Duration(milliseconds: 150));
    expect(engine.positionFrame, before, reason: 'a held pointer has not committed a tap');
    await canceled.moveBy(Offset(bounds.width, 0));
    expect(session.position, session.duration);
    expect(engine.render(64, input: mic), everyElement(0));
    expect(engine.positionFrame, before);
    await canceled.cancel();
    expect(engine.isPlaying, isTrue);
    expect(engine.positionFrame, before);

    final drag = await tester.startGesture(start);
    await drag.moveBy(Offset(bounds.width * 0.2, 0));
    final target = session.position;
    expect(target, inInclusiveRange(session.duration * 0.65, session.duration * 0.75));
    expect(engine.render(64, input: mic), everyElement(0));
    await drag.up();
    expect(engine.positionSeconds, closeTo(target, 0.001));
    expect(engine.render(64, input: mic), anyElement(isNot(0)));

    final dismissed = await tester.startGesture(start);
    await dismissed.moveBy(Offset(bounds.width * 0.2, 0));
    await tester.pumpWidget(const SizedBox());
    await dismissed.cancel();
    expect(tester.takeException(), isNull);
  }, skip: lib == null || lib.isEmpty);

  testWidgets('leaving the practice page keeps what was sung, and asks about the recording', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final before = (await tester.runAsync(() => services.songs.loadHistory(song.id)))!.length;
    late PracticeSession session;
    Future<void>? saved;
    await tester.pumpWidget(practiceLauncher(ref, onSession: (s) => session = s, onLeave: (f) => saved = f));
    await tester.tap(find.text('练习'));
    await settleIo(tester, rounds: 10);
    expect(session.started, isTrue);
    expect(find.text('第 1 / 2 句'), findsOneWidget);
    // The first line, sung; nobody looks at the scores.
    session.play();
    await singUntil(tester, session, ref.lines[0].end + 0.5);
    expect(session.scorer.lineResult(0).attempted, isTrue);
    // More than half of this short song is recorded: leaving asks first,
    // and nothing is left until it is answered.
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the question's entrance
    expect(find.text('保存刚才唱的录音？'), findsOneWidget);
    expect(find.byType(PracticePage), findsOneWidget);
    await screenshot(tester, '3c_leave_with_take');
    await tester.tap(find.text('不保存'));
    await tester.pump();
    expect(saved, isNotNull, reason: 'the page below gets the save to wait for');
    var done = false;
    saved!.then((_) => done = true);
    for (var i = 0; i < 60 && !done; i++) {
      await settleIo(tester, rounds: 1);
    }
    expect(done, isTrue);
    final history = (await tester.runAsync(() => services.songs.loadHistory(song.id)))!;
    expect(history, hasLength(before + 1));
    expect(history.last.lineScores.keys, [0]);
    await settleIo(tester, rounds: 5);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PracticePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);

  testWidgets('listening without singing and going back keeps nothing and asks nothing', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final before = (await tester.runAsync(() => services.songs.loadHistory(song.id)))!.length;
    final count = (await tester.runAsync(() => services.songs.load(song.id)))!.practiceCount;
    late PracticeSession session;
    Future<void>? saved;
    await tester.pumpWidget(practiceLauncher(ref, onSession: (s) => session = s, onLeave: (f) => saved = f));
    await tester.tap(find.text('练习'));
    await settleIo(tester, rounds: 10);
    session.play();
    final engine = session.engine!;
    while (engine.positionSeconds < ref.lines[0].end + 0.5) {
      engine.render(512, input: Float32List(512)); // the song plays; nobody sings
      await tester.pump(const Duration(milliseconds: 11));
    }
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    expect(find.text('保存刚才唱的录音？'), findsNothing);
    expect(saved, isNotNull);
    var done = false;
    saved!.then((_) => done = true);
    for (var i = 0; i < 60 && !done; i++) {
      await settleIo(tester, rounds: 1);
    }
    expect(done, isTrue);
    expect((await tester.runAsync(() => services.songs.loadHistory(song.id)))!, hasLength(before));
    expect((await tester.runAsync(() => services.songs.load(song.id)))!.practiceCount, count);
    await settleIo(tester, rounds: 5);
    await tester.pump(const Duration(milliseconds: 600));
    expect(find.byType(PracticePage), findsNothing);
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);

  testWidgets('practice: 导唱 on and off, and keeping the recording on the way out', (tester) async {
    phone(tester);
    final ref = (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final recordings = (await tester.runAsync(() => services.songs.loadRecordings(song.id)))!.length;
    late PracticeSession session;
    await tester.pumpWidget(practiceLauncher(ref, onSession: (s) => session = s, onLeave: (_) {}));
    await tester.tap(find.text('练习'));
    await settleIo(tester, rounds: 10);
    final engine = session.engine!;
    final vocal = readWavFile(services.songs.pathFor(song.id, song.vocalsFile)).samples;
    // The accompaniment of this song is silence: what plays is 导唱.
    double guide() {
      session.seek(ref.lines[0].start + 0.3);
      final at = engine.positionFrame;
      final out = engine.render(2048, input: Float32List(2048));
      var level = 0.0, expected = 0.0;
      for (var i = 0; i < 2048; i++) {
        level = math.max(level, out[2 * i].abs());
        expected = math.max(expected, vocal[at + i].abs());
      }
      return level / expected;
    }

    expect(services.settings.guideVocalOn, isTrue);
    session.play();
    expect(guide(), closeTo(services.settings.guideVocalVolume, 0.02));
    await tester.tap(find.text('导唱：开'));
    await tester.pump();
    expect(services.settings.guideVocalOn, isFalse);
    expect(find.text('导唱：关'), findsOneWidget);
    expect(guide(), lessThan(1e-3), reason: 'the accompaniment alone');
    await tester.tap(find.text('导唱：关'));
    await tester.pump();
    expect(services.settings.guideVocalOn, isTrue);
    expect(guide(), closeTo(services.settings.guideVocalVolume, 0.02));

    // Sung through: leaving offers to keep the recording.
    session.seek(0);
    await singUntil(tester, session, 9.6);
    await tester.tap(find.byType(BackButton));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400)); // the question's entrance
    await tester.tap(find.text('保存'));
    // Kept (the encoding takes its time), then the page goes.
    for (var i = 0; i < 80 && find.byType(PracticePage).evaluate().isNotEmpty; i++) {
      await settleIo(tester, rounds: 2);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(find.byType(PracticePage), findsNothing);
    final kept = (await tester.runAsync(() => services.songs.loadRecordings(song.id)))!;
    expect(kept, hasLength(recordings + 1));
    await tester.pumpWidget(const SizedBox());
  }, skip: lib == null || lib.isEmpty);
}
