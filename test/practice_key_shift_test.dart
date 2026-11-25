import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/audio/key_shift_cache.dart';
import 'package:yintrace/src/audio/shifted_track.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/dsp/pitch.dart';
import 'package:yintrace/src/export/mixdown.dart';
import 'package:yintrace/src/export/recordings.dart';
import 'package:yintrace/src/library/recording.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/models/model_recipe.dart' show sha256OfFileSync;
import 'package:yintrace/src/practice/live_pitch.dart';
import 'package:yintrace/src/practice/practice_session.dart';
import 'package:yintrace/src/practice/scoring.dart';
import 'package:yintrace/src/ui/export_page.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';
import 'package:yintrace/src/ui/practice_page.dart';
import 'package:yintrace/src/ui/score_trend.dart';
import 'package:yintrace/src/ui/theme.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

const _sr = 44100;
const _duration = 3.2;
const _guideHz = 440.0, _accHz = 220.0;

Float32List _tone(double hz, int frames, {int at = 0, double level = 0.20}) => Float32List.fromList([
  for (var i = 0; i < frames; i++) level * math.sin(2 * math.pi * hz * (at + i) / _sr),
]);

// Amplitude at a known frequency, from one channel of the rendered audio.
double _amplitudeAt(Float32List samples, double hz, {int channels = 2}) {
  final n = samples.length ~/ channels;
  var real = 0.0, imaginary = 0.0;
  for (var i = 0; i < n; i++) {
    final phase = 2 * math.pi * hz * i / _sr;
    final weight = math.pow(math.sin(math.pi * i / n), 2).toDouble();
    final v = samples[channels * i] * weight;
    real += v * math.cos(phase);
    imaginary += v * math.sin(phase);
  }
  return 4 * math.sqrt(real * real + imaginary * imaginary) / n;
}

void main() {
  final hasNative = Platform.environment['YINTRACE_AUDIO_LIB'] != null;
  late Directory tmp;
  late SongRepository repo;
  late SongMeta meta;
  late SongReference reference;
  late String accPath;

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('yt_key_shift');
    repo = SongRepository(Directory('${tmp.path}/songs'), keyShiftRoot: Directory('${tmp.path}/cache'));
    meta = SongMeta(
      id: 'song',
      title: '试唱',
      createdAt: DateTime(2026),
      duration: _duration,
      lyrics: '[00:00.35]雨\n[00:01.65]风',
      vocalsFile: 'vocals.wav',
      accompanimentFile: 'acc.wav',
    );
    RefLine line(int index, double start, double end, String text) => RefLine(
      index: index,
      lrcStart: start,
      lrcEnd: end,
      text: text,
      tokens: [
        RefToken(
          text: text,
          start: start,
          end: end,
          notes: [RefNote(start: start, end: end, midi: 69)],
        ),
      ],
    );
    reference = SongReference(
      lines: [line(0, 0.35, 1.12, '雨'), line(1, 1.65, 2.78, '风')],
      duration: _duration,
    );
    await repo.save(meta);
    await repo.saveReference(meta.id, reference);
    accPath = repo.pathFor(meta.id, meta.accompanimentFile!);
    writeWavFile(accPath, _tone(_accHz, (_duration * _sr).round()), 1, _sr);
    writeWavFile(repo.pathFor(meta.id, meta.vocalsFile), _tone(_guideHz, (_duration * _sr).round()), 1, _sr);
  });

  tearDown(() => tmp.deleteSync(recursive: true));

  PracticeSession makeSession({SongMeta? song, LoadPracticeTrack? loadTrack, bool background = true}) =>
      PracticeSession(
        meta: song ?? meta,
        reference: reference,
        repository: repo,
        settings: AppSettings(null)..headphoneTipSeen = true,
        loadTrack: loadTrack,
        engineFactory: () => PracticeEngine.create(mode: EngineMode.offline),
        decodeInBackground: background,
      );

  void singUntil(PracticeSession session, double end, double hz) {
    final e = session.engine!;
    while (e.isPlaying && e.positionSeconds < end) {
      e.render(512, input: _tone(hz, 512, at: e.positionFrame, level: 0.45));
      session.tick();
    }
  }

  test('transposition scores the shifted note and still supports octave tolerance', () {
    for (final octaveTolerant in [false, true]) {
      final scorer = PracticeScorer(
        reference,
        options: ScoringOptions(transpose: 2, octaveTolerant: octaveTolerant),
      );
      ScoredSample sample(double time, double midi) => scorer.add(
        LivePitch(songTime: time, clockTime: time, midi: midi, levelDb: -18, playing: true, aperiodicity: 0),
      );
      final on = sample(0.40, 71);
      expect(on.verdict, PitchVerdict.great);
      expect(on.referenceMidi, 71);
      expect(on.pitch.midi, 71);
      expect(sample(0.41, 69).deviationCents, -200);
      final octave = sample(0.42, 59);
      expect(octave.verdict, octaveTolerant ? PitchVerdict.great : PitchVerdict.off);
      expect(octave.referenceMidi, 71);
      expect(octave.pitch.midi, 59);
    }
  });

  test('key preferences belong to a song and old metadata is read in the original key', () async {
    const id = 'other-song';
    final other = SongMeta.fromJson(meta.toJson()..['id'] = id);
    await repo.save(other);
    expect((await repo.load(meta.id)).transpose, 0);
    final legacyRun = PracticeRecord(at: DateTime(2026, 1, 2), score: 94, lineScores: {0: 94});
    expect(PracticeRecord.fromJson(legacyRun.toJson()).transpose, 0);
    expect(
      Recording.fromJson({
        'id': 'old',
        'file': 'old.wav',
        'start': 0,
        'duration': 1,
        'mix': {'reverb': 0.4},
      }).transpose,
      0,
    );
    expect(MixSettings.fromJson({}).transpose, 0);

    await repo.saveTranspose(meta.id, -3);
    await repo.saveTranspose(id, 5);
    await repo.save(meta); // a metadata snapshot made before the key change
    final reopened = SongRepository(repo.root, keyShiftRoot: repo.keyShiftRoot);
    expect((await reopened.load(meta.id)).transpose, -3);
    expect((await reopened.load(id)).transpose, 5);

    final run = PracticeRecord(at: DateTime(2026), score: 95, lineScores: {0: 95, 1: 95}, transpose: -3);
    await reopened.addPractice(meta.id, run);
    await reopened.addPractice(meta.id, legacyRun, keep: 1);
    expect(
      (await reopened.load(meta.id)).bestScoreTranspose,
      -3,
      reason: 'keep the best key when old history ages out',
    );
    expect((await reopened.loadHistory(meta.id)).single.transpose, 0);
  });

  test(
    'switching key while singing starts a clean run and audition and export use the recorded key',
    () async {
      final refFile = File(repo.pathFor(meta.id, SongRepository.referenceFile));
      final originalReference = refFile.readAsBytesSync();
      final guidePath = repo.pathFor(meta.id, meta.vocalsFile);
      final originals = [sha256OfFileSync(accPath), sha256OfFileSync(guidePath)];
      final session = makeSession();
      addTearDown(session.dispose);
      await session.start();
      session.play();
      singUntil(session, 1.3, _guideHz);
      final e = session.engine!;
      final position = e.positionFrame;
      expect(session.scorer.results().first.score, greaterThan(90));
      expect(session.take!.transpose, 0);
      final oldTrail = [for (final p in session.points) (p.time, p.midi)];

      final progress = <double>[];
      session.addListener(() {
        if (session.keyShiftProgress case final value?) progress.add(value);
      });
      final change = session.setTranspose(2);
      expect(session.changingKey, isTrue);
      expect(session.isPlaying, isFalse);
      session.seek(0.5); // A transport gesture while the key loads.
      await change;
      expect(session.error, isNull);
      expect(session.keyShiftNotice, isNull);
      expect(session.changingKey, isFalse);
      expect(progress.any((v) => v > 0 && v < 1), isTrue);
      expect(session.isPlaying, isTrue);
      expect(e.positionFrame, position);
      expect(e.lengthFrames, (_duration * _sr).round());
      expect(session.scorer.results().every((line) => !line.attempted), isTrue);
      expect([for (final p in session.points) (p.time, p.midi)], oldTrail);
      expect(session.points.every((p) => p.cents == null), isTrue);
      expect(session.take!.isEmpty, isTrue);
      expect(session.take!.transpose, 2);
      expect((await repo.load(meta.id)).transpose, 2);

      final ratio = midiToHz(71) / _guideHz;
      singUntil(session, 2.98, _guideHz * ratio);
      session.pause();
      final history = await session.save();
      expect(history!.score, greaterThan(90));
      final runs = await repo.loadHistory(meta.id);
      expect(runs.map((r) => r.transpose), [0, 2]);
      expect(runs.map((r) => r.lineScores.keys.toList()), [
        [0],
        [1],
      ]);
      expect(refFile.readAsBytesSync(), originalReference);

      // Solo the guide and verify that it was shifted, too.
      session.seek(1.68);
      e.setTrackGain(TrackSlot.accompaniment, 0);
      e.play();
      final guide = e.render(_sr ~/ 2);
      e.pause();
      expect(_amplitudeAt(guide, _guideHz * ratio), greaterThan(0.055));
      expect(_amplitudeAt(guide, _guideHz), lessThan(0.005));
      session.applyMix();

      final take = session.take!;
      final recording = await keepTake(repo, meta.id, take, score: history.score, background: false);
      expect(recording.transpose, 2);
      final stored = (await repo.loadRecordings(meta.id)).single;
      expect(stored.mix.copy().transpose, 2);
      final voicePath = repo.recordingPath(meta.id, stored);
      final originalTake = sha256OfFileSync(voicePath);
      await KeyShiftCache.trimInBackground(repo.keyShiftRoot.path, maxBytes: 0);
      expect(repo.keyShiftDir(meta.id).listSync(), isEmpty);
      const auditionFrame = 2 * _sr;
      session.listenBack();
      expect(session.listening, ListenKind.take);
      e.seekFrame(auditionFrame);
      final audition = e.render(_sr ~/ 2);
      expect(_amplitudeAt(audition, _accHz * ratio), greaterThan(0.12));
      expect(_amplitudeAt(audition, _accHz), lessThan(0.005));
      expect(_amplitudeAt(audition, _guideHz * ratio), greaterThan(0.35));

      await repo.saveTranspose(meta.id, -4); // the next practice picks a different key
      final cache = await repo.prepareKeyShiftCache(meta.id);
      final preview = await preparePreviewInBackground(voicePath, accPath, transpose: stored.transpose, cache: cache);
      expect(preview.accompaniment!.length, e.lengthFrames * 2);
      expect(_amplitudeAt(preview.accompaniment!, _accHz * ratio), greaterThan(0.17));
      expect(repo.keyShiftDir(meta.id).listSync().whereType<File>(), hasLength(1));
      await KeyShiftCache.trimInBackground(repo.keyShiftRoot.path, maxBytes: 0);
      final path = await runExport(
        ExportJob(
          voicePath: voicePath,
          voiceStart: stored.start,
          accompanimentPath: accPath,
          keyShiftCache: cache,
          songDuration: meta.duration,
          settings: stored.mix.copy()..reverb = 0,
          outputBase: '${tmp.path}/mix',
        ),
      );
      final mix = NativeAudio.decodeFile(path).samples.sublist(2 * auditionFrame, 2 * auditionFrame + _sr);
      expect(_amplitudeAt(mix, _accHz * ratio), greaterThan(0.10));
      expect(_amplitudeAt(mix, _guideHz * ratio), greaterThan(0.33));
      expect(_amplitudeAt(mix, _accHz), lessThan(0.005));
      expect(repo.keyShiftDir(meta.id).listSync().whereType<File>(), hasLength(1));
      expect([sha256OfFileSync(accPath), sha256OfFileSync(guidePath)], originals);
      expect(sha256OfFileSync(voicePath), originalTake);
    },
    skip: !hasNative,
  );

  test('PCM cache hits skip processing, source edits and truncation regenerate it', () async {
    final cache = (await repo.prepareKeyShiftCache(meta.id))!;
    final track = ShiftedTrack(accPath, -6, cache: cache);
    ShiftedTrack(accPath, 0, cache: cache).decode();
    expect(cache.directory.listSync(), isEmpty);
    final progress = <double>[];
    final cold = track.decode(onProgress: progress.add);
    expect(progress.length, greaterThan(2));
    final file = cache.directory.listSync().whereType<File>().single;
    expect(file.lengthSync(), 44 + cold.frames * 4);

    // An existing v1 WAV with this key and source is still a hit.
    final identity = sha256.convert(utf8.encode('acc.wav\n${sha256OfFileSync(accPath)}'));
    final legacy = file.renameSync('${cache.directory.path}/v1-$_sr--6-$identity.wav');
    progress.clear();
    final hit = track.decode(onProgress: progress.add);
    expect(progress, [1]);
    expect(hit.frames, cold.frames);
    expect(hit.samples[2345], closeTo(cold.samples[2345], 0.00005));
    expect(legacy.existsSync(), isFalse);
    expect(file.existsSync(), isTrue);

    file.writeAsBytesSync([0, 1, 2]);
    final repaired = track.decode();
    expect(repaired.frames, cold.frames);
    expect(file.lengthSync(), greaterThan(3));
    writeWavFile(accPath, _tone(312, cold.frames), 1, _sr);
    progress.clear();
    expect(track.decode(onProgress: progress.add).frames, cold.frames);
    expect(progress.length, greaterThan(2));
    expect(file.existsSync(), isFalse);
    expect(cache.directory.listSync().whereType<File>(), hasLength(1));

    final reopened = makeSession(song: await repo.load(meta.id));
    await reopened.start();
    expect(reopened.transpose, 0);
    reopened.dispose();
    await repo.delete(meta.id);
    expect(repo.keyShiftDir(meta.id).existsSync(), isFalse);
  }, skip: !hasNative);

  test('a cache directory removed during processing leaves playable audio and is rebuilt on next use', () async {
    final cache = (await repo.prepareKeyShiftCache(meta.id))!;
    final track = ShiftedTrack(accPath, 3, cache: cache);
    final audio = track.decode(onProgress: (p) {
      if (p == 0.05 && cache.directory.existsSync()) cache.directory.deleteSync(recursive: true);
    });
    expect(cache.directory.existsSync(), isFalse);
    expect(_amplitudeAt(audio.samples, _accHz * midiToHz(72) / _guideHz), greaterThan(0.15));

    await repo.prepareKeyShiftCache(meta.id);
    expect(track.decode().frames, audio.frames);
    expect(cache.directory.listSync().whereType<File>(), hasLength(1));
    final progress = <double>[];
    expect(track.decode(onProgress: progress.add).frames, audio.frames);
    expect(progress, [1]);
  }, skip: !hasNative);

  test('the remembered key is loaded and a partially failed switch restores both original tracks', () async {
    await repo.saveTranspose(meta.id, 3);
    final session = makeSession(
      song: await repo.load(meta.id),
      loadTrack: (e, slot, track, _) async {
        if (track.transpose == -4 && slot == TrackSlot.guideVocal) throw StateError('test failure');
        final audio = track.decode();
        e.loadTrackPcm(slot, audio.samples, audio.channels);
      },
    );
    addTearDown(session.dispose);
    await session.start();
    expect(session.transpose, 3);
    expect(session.take!.transpose, 3);
    session.seek(0.7);
    session.play();
    final e = session.engine!;
    final at = e.positionFrame;
    await session.setTranspose(-4);
    expect(session.keyShiftNotice, '变调失败，已回到原调');
    expect(session.error, isNull);
    expect(session.changingKey, isFalse);
    expect(session.isPlaying, isTrue);
    expect(e.positionFrame, at);
    expect(session.transpose, 0);
    expect((await repo.load(meta.id)).transpose, 0);
    final original = e.render(_sr ~/ 2);
    expect(_amplitudeAt(original, _accHz), greaterThan(0.15));
    expect(_amplitudeAt(original, _guideHz), greaterThan(0.055));
  }, skip: !hasNative);

  test('unplugging headphones during a key switch keeps playback paused', () async {
    final release = Completer<void>();
    final pending = Completer<void>();
    final session = makeSession(
      loadTrack: (e, slot, track, _) async {
        if (track.transpose != 0 && slot == TrackSlot.accompaniment) {
          pending.complete();
          await release.future;
        }
        final audio = track.decode();
        e.loadTrackPcm(slot, audio.samples, audio.channels);
      },
    );
    addTearDown(session.dispose);
    await session.start();
    session.play();
    final change = session.setTranspose(2);
    await pending.future;
    session.engine!.signalAudioEvent(AudioEvents.deviceLost);
    release.complete();
    await change;
    expect(session.transpose, 2);
    expect(session.isPlaying, isFalse);
    expect(session.pauseReason, contains('耳机断开'));
  }, skip: !hasNative);

  testWidgets('practice settings show the pending key, progress, and shifted target and graph', (
    tester,
  ) async {
    final settings = AppSettings(null)..headphoneTipSeen = true;
    final services = AppServices(
      settings: settings,
      songs: repo,
      models: ModelManager(dir: Directory('${tmp.path}/models'), loadRecipe: loadBundledRecipe),
    );
    final release = Completer<void>();
    final session = makeSession(
      loadTrack: (e, slot, track, progress) async {
        if (track.transpose == 2 && slot == TrackSlot.accompaniment) {
          progress?.call(0.8);
          await release.future;
        }
        if (track.transpose == -3) throw StateError('test failure');
        final audio = track.decode();
        e.loadTrackPcm(slot, audio.samples, audio.channels);
      },
    );

    Future<void> waitUntil(bool Function() ready) async {
      for (var attempt = 0; attempt < 120 && !ready(); attempt++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 10)));
        await tester.pump(const Duration(milliseconds: 16));
      }
      expect(ready(), isTrue);
      await tester.pump();
    }

    Future<void> animateRoute() async {
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
    }

    final keyMenu = find.byWidgetPredicate((w) => w is DropdownButton<int>);
    Future<void> choose(String name) async {
      await tester.tap(keyMenu);
      await animateRoute();
      await tester.tap(find.text(name).last);
      await tester.pump();
    }

    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: buildTheme(Brightness.light),
          home: PracticePage(meta: meta, reference: reference, sessionFactory: (_) => session),
        ),
      ),
    );
    await waitUntil(() => session.started);
    expect(find.text('A4'), findsOneWidget);
    await tester.tap(find.byTooltip('练习设置'));
    await animateRoute();
    expect(find.text('升降调'), findsOneWidget);
    final menu = tester.widget<DropdownButton<int>>(keyMenu);
    expect(menu.value, 0);
    expect(menu.items!.map((item) => item.value), List.generate(13, (i) => i - 6));
    await choose('升 2 个半音');
    await waitUntil(() => session.keyShiftProgress == 0.4);
    expect(find.text('正在变调… 40%'), findsWidgets);
    expect(tester.widget<DropdownButton<int>>(keyMenu).onChanged, isNull);
    release.complete();
    await waitUntil(() => !session.changingKey);
    expect(tester.widget<DropdownButton<int>>(keyMenu).value, 2);
    await tester.tap(find.byType(CloseButton));
    await animateRoute();

    expect(find.text('B4'), findsOneWidget);
    final graph = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<PitchGraphPainter>()
        .single;
    expect(graph.transpose, 2);
    expect(graph.reference!.notes.first.midi, 69);
    session.points.add(const UserPoint(0.8, 69, PitchVerdict.off, -200));
    session.pause();
    await tester.pump();
    final liveGraph = tester
        .widgetList<CustomPaint>(find.byType(CustomPaint))
        .map((w) => w.painter)
        .whereType<PitchGraphPainter>()
        .single;
    expect(liveGraph.user.single.midi, 69);

    await tester.tap(find.byTooltip('练习设置'));
    await animateRoute();
    await choose('降 3 个半音');
    await waitUntil(() => session.keyShiftNotice != null && !session.changingKey);
    expect(find.text('变调失败，已回到原调'), findsWidgets);
    expect(tester.widget<DropdownButton<int>>(keyMenu).value, 0);
    await tester.tap(find.byType(CloseButton));
    await animateRoute();
    expect(find.text('A4'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(session.save);
  }, skip: !hasNative);

  testWidgets('score trends mark the key of recent scores', (tester) async {
    final entries = [
      PracticeRecord(at: DateTime(2026, 1, 1), score: 71, lineScores: {0: 71}, transpose: -3),
      PracticeRecord(at: DateTime(2026, 1, 2), score: 88, lineScores: {0: 88}, transpose: 2),
    ];
    await tester.pumpWidget(
      MaterialApp(
        theme: buildTheme(Brightness.light),
        home: Scaffold(
          body: Column(
            children: [
              ScoreTrend(history: entries),
              const LineScoreSparkline(scores: [71, 88], transposes: [-3, 2]),
            ],
          ),
        ),
      ),
    );
    expect(find.textContaining('88 分（+2）'), findsOneWidget);
    expect(find.byTooltip('这一句最近 2 次：71（-3）、88（+2）'), findsOneWidget);
  });
}
