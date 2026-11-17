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
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/ui/model_setup.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/practice/segment_player.dart';
import 'package:yintrace/src/practice/take_recorder.dart';
import 'package:yintrace/src/export/recordings.dart';
import 'package:yintrace/src/ui/about_page.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace/src/ui/benchmark_page.dart';
import 'package:yintrace/src/ui/export_page.dart';
import 'package:yintrace/src/ui/import_page.dart';
import 'package:yintrace/src/ui/library_page.dart';
import 'package:yintrace/src/ui/pitch_editor_page.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';
import 'package:yintrace/src/ui/settings_page.dart';
import 'package:yintrace/src/ui/practice_page.dart';
import 'package:yintrace/src/ui/results_sheet.dart';
import 'package:yintrace/src/ui/score_trend.dart';
import 'package:yintrace/src/ui/song_page.dart';
import 'package:yintrace/src/ui/song_share.dart';
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

  testWidgets('pitch editor moves a character, leaves it out of the score and restores it', (tester) async {
    phone(tester);
    late SegmentPlayer player;
    await tester.pumpWidget(
      host(
        services,
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
    await settleIo(tester, rounds: 20);
    expect(find.text('第 2 句，共 2 句'), findsOneWidget);
    await tester.tap(find.text('记'));
    await tester.pump();
    expect(find.text('「记」'), findsOneWidget);
    Future<RefToken> stored() async =>
        (await tester.runAsync(() => services.songs.loadReference(song.id)))!.lines[1].tokens[3];
    final detected = (await stored()).notes.first.midi;
    await screenshot(tester, '2b_pitch_editor');

    // Listen to the original: exactly the vocal around the character.
    await tester.tap(find.text('听原唱'));
    await settleIo(tester, rounds: 3);
    final engine = player.engine!;
    expect(engine.isPlaying, isTrue);
    final ref = await tester.runAsync(() => services.songs.loadReference(song.id));
    final from = ref!.lines[1].tokens[3].start - 0.12;
    final vocal = readWavFile(services.songs.pathFor(song.id, song.vocalsFile)).samples;
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
    await settleIo(tester, rounds: 5);
    expect((await stored()).notes.first.midi, closeTo(detected + 12, 1e-6));
    expect(find.textContaining('调高了 1 个八度'), findsOneWidget);
    await tester.tap(find.text('降半音'));
    await settleIo(tester, rounds: 5);
    expect((await stored()).shift, 11);
    // Quick taps: every one is saved, in order.
    for (var i = 0; i < 3; i++) {
      await tester.tap(find.text('升半音'));
      await tester.pump();
    }
    // The writes are queued one after another: wait for the last one
    // (a busy machine takes longer than the 10 rounds that used to be here).
    await settleIo(tester, rounds: 10);
    for (var i = 0; i < 40 && (await stored()).shift != 14; i++) {
      await settleIo(tester, rounds: 2);
    }
    expect((await stored()).shift, 14);
    expect(find.textContaining('调高了 14 个半音'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('这个字不计分'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('这个字不计分'));
    await settleIo(tester, rounds: 10);
    expect((await stored()).skip, isTrue);
    expect(find.text('不计分'), findsOneWidget);

    await tester.scrollUntilVisible(find.text('恢复自动识别'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('恢复自动识别'));
    await settleIo(tester, rounds: 5);
    final restored = await stored();
    expect(restored.notes.first.midi, closeTo(detected, 1e-6));
    expect(restored.corrected, isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

  testWidgets('pitch editor sets where a character starts, and the rest of the line follows', (tester) async {
    phone(tester);
    await tester.pumpWidget(
      host(
        services,
        PitchEditorPage(
          songId: song.id,
          line: 1,
          decodeInBackground: false,
          playerFactory: () => SegmentPlayer(
            engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
            configureSession: false,
          ),
        ),
      ),
    );
    await settleIo(tester, rounds: 20);
    Future<SongReference> stored() async => (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final before = await stored();
    final start = before.lines[1].tokens[4].start;
    final firstLine = [for (final t in before.lines[0].tokens) (t.start, t.end, t.notes.length)];
    await tester.tap(find.text('得'));
    await tester.pump();
    final shown = find.textContaining(RegExp(r'^从 \d+:\d\d\.\d\d 开始$'));
    expect(shown, findsOneWidget);

    // Two quick taps add up; the result is saved.
    await tester.scrollUntilVisible(find.byTooltip('推后 0.05 秒'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.byTooltip('推后 0.05 秒'));
    await tester.pump();
    await tester.tap(find.byTooltip('推后 0.05 秒'));
    await settleIo(tester, rounds: 20);
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
    await tester.longPress(find.byWidgetPredicate((w) => w is CustomPaint && w.painter is PitchGraphPainter));
    await settleIo(tester, rounds: 20);
    expect((await stored()).lines[1].tokens[5].pinned, isNotNull);

    // Restoring the line puts every character back where the aligner has it.
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这一句全部恢复自动识别'));
    await settleIo(tester, rounds: 20);
    final restored = (await stored()).lines[1];
    expect(restored.tokens.every((t) => t.pinned == null), isTrue);
    expect(restored.tokens[4].start, closeTo(start, 1e-6));
    expect(restored.tokens.any((t) => t.corrected), isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

  testWidgets('pitch editor: taps while a line is being aligned add up and keep each other', (tester) async {
    phone(tester);
    // Each re-alignment waits until the test lets it finish, as on the
    // phone, where it runs in the background.
    final gates = <Completer<void>>[];
    await tester.pumpWidget(
      host(
        services,
        PitchEditorPage(
          songId: song.id,
          line: 1,
          decodeInBackground: false,
          playerFactory: () => SegmentPlayer(
            engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
            configureSession: false,
          ),
          retimer: (track, lines, ref, line, pins) async {
            final gate = Completer<void>();
            gates.add(gate);
            await gate.future;
            return retimeLine(track, lines, ref, line, pins);
          },
        ),
      ),
    );
    await settleIo(tester, rounds: 20);
    Future<SongReference> stored() async => (await tester.runAsync(() => services.songs.loadReference(song.id)))!;
    final before = (await stored()).lines[1];
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
    await tester.tap(find.byTooltip('推后 0.05 秒'));
    await tester.pump();
    expect(find.text('你调过'), findsOneWidget);
    await nudge('带');
    expect(gates, hasLength(1));
    for (var round = 0; round < 6; round++) {
      for (final g in gates) {
        if (!g.isCompleted) g.complete();
      }
      await settleIo(tester, rounds: 5);
    }
    final after = (await stored()).lines[1];
    expect(after.tokens[4].pinned, closeTo(before.tokens[4].start + 0.1, 1e-3));
    expect(after.tokens[5].pinned, closeTo(before.tokens[5].start + 0.05, 1e-3));

    // Put the line back for the tests after this one.
    await tester.tap(find.byIcon(Icons.more_horiz_rounded));
    await tester.pumpAndSettle();
    await tester.tap(find.text('这一句全部恢复自动识别'));
    for (var round = 0; round < 4; round++) {
      for (final g in gates) {
        if (!g.isCompleted) g.complete();
      }
      await settleIo(tester, rounds: 5);
    }
    expect((await stored()).lines[1].tokens.any((t) => t.pinned != null), isFalse);
    await tester.pumpWidget(const SizedBox());
  }, skip: Platform.environment['YINTRACE_AUDIO_LIB'] == null);

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
    expect(find.text('导入 YinTrace 歌曲文件'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '选择 YinTrace 文件'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);
    expect(find.text('选择音频'), findsNothing);
    expect(find.text('去和声'), findsNothing);
    expect(find.widgetWithText(FilledButton, '分离人声，生成音高图'), findsNothing);
    await screenshot(tester, '5b_import_song_file');
    await tester.tap(find.text('添加新歌曲'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 400));
    expect(find.text('导入 YinTrace 歌曲文件'), findsNothing);
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
    await tester.tap(find.text('导出歌曲文件'));
    await settleIo(tester, rounds: 5);
    final file = '${out.path}/夜航（示例） - 演示.yintrace';
    expect(shared, [file]);
    expect(File(file).lengthSync(), greaterThan(100000));
    expect(find.text('已导出 夜航（示例） - 演示.yintrace'), findsOneWidget);
    await tester.tap(find.text('分享或存到别处'));
    await tester.pump();
    expect(shared, [file, file]);
    await tester.pumpWidget(const SizedBox());

    // The receiver: some other file is refused and the page stays usable...
    String? picked = '${tmp.path}/vocal.wav';
    await tester.pumpWidget(host(services, ImportPage(pickSongFile: () async => picked, background: false)));
    await tester.pump();
    await tester.tap(find.text('导入yintrace文件'));
    await tester.pump(const Duration(milliseconds: 400));
    await tester.tap(find.widgetWithText(FilledButton, '选择 YinTrace 文件'));
    await settleIo(tester, rounds: 5);
    expect(find.text('这不是 YinTrace 导出的歌曲文件'), findsOneWidget);
    expect(find.text('导入 YinTrace 歌曲文件'), findsOneWidget);
    expect(find.widgetWithText(FilledButton, '选择 YinTrace 文件'), findsOneWidget);
    // ...and the song file opens as a new song that was never practised.
    picked = file;
    await tester.tap(find.widgetWithText(FilledButton, '选择 YinTrace 文件'));
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
    expect(find.text('可以腾出 67 MB。已经导入的歌不受影响；下次导入整首歌时要重新下载。'), findsOneWidget);
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

  testWidgets('about page credits the models and opens the licenses', (tester) async {
    phone(tester);
    await tester.pumpWidget(host(services, const AboutPage()));
    await tester.pump();
    expect(find.textContaining('Anjok07 和 aufr33'), findsOneWidget);
    expect(find.textContaining('hf-mirror'), findsNothing);
    // Further down the app states its own license and where the source is.
    await tester.scrollUntilVisible(find.text('许可全文与开源组件'), 300, scrollable: find.byType(Scrollable).first);
    expect(find.textContaining('AGPL-3.0'), findsOneWidget);
    expect(find.textContaining('github.com/zhikkz/YinTrace'), findsOneWidget);
    await screenshot(tester, '8_about');
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
