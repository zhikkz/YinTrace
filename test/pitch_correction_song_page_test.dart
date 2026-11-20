import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/app/pitch_correction_session.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace/src/ui/pitch_editor_page.dart';
import 'package:yintrace/src/ui/pitch_graph.dart';
import 'package:yintrace/src/ui/song_page.dart';

SongReference _reference({double? pin}) {
  final start = pin ?? 0.3;
  return SongReference(
    duration: 2,
    lines: [
      RefLine(
        index: 0,
        text: '春',
        lrcStart: 0.3,
        tokens: [
          RefToken(
            text: '春',
            start: start,
            end: 1.5,
            pinned: pin,
            notes: [RefNote(start: start, end: 1.5, midi: 60)],
          ),
        ],
      ),
    ],
  );
}

class _PausingSongRepository extends SongRepository {
  _PausingSongRepository(super.root);

  Future<void>? nextWriteGate;

  @override
  Future<void> saveReference(String id, SongReference ref) async {
    if (nextWriteGate case final gate?) {
      nextWriteGate = null;
      await gate;
    }
    await super.saveReference(id, ref);
  }
}

Future<void> _waitFor(WidgetTester tester, bool Function() ready) async {
  for (var attempt = 0; attempt < 40 && !ready(); attempt++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 20)),
    );
    await tester.pump();
  }
  expect(ready(), isTrue);
}

void main() {
  late AppServices services;
  late String id;
  final songGraph = find.byType(LinePitchGraph);

  Future<void> openSong(
    WidgetTester tester, {
    bool useModel = false,
    SongRepository Function(Directory) createRepository = SongRepository.new,
  }) async {
    final temp = Directory.systemTemp.createTempSync('yt-correction-refresh');
    addTearDown(() => temp.deleteSync(recursive: true));
    final songs = createRepository(Directory('${temp.path}/songs'));
    id = songs.newSongId();
    await tester.runAsync(() async {
      await songs.save(
        SongMeta(
          id: id,
          title: '春风',
          createdAt: DateTime(2026),
          duration: 2,
          lyrics: '[00:00.30]春',
          vocalsFile: 'vocals.wav',
          modelInfo: {if (useModel) 'alignment': 'HuBERTFA'},
        ),
      );
      await songs.saveReference(id, _reference());
      await songs.savePitchTrack(
        id,
        PitchTrack(
          hopSeconds: 0.01,
          midi: Float32List(200),
          rmsDb: Float32List(200),
          aperiodicity: Float32List(200),
        ),
      );
    });
    services = AppServices(
      settings: AppSettings(null),
      songs: songs,
      models: ModelManager(
        dir: Directory('${temp.path}/models'),
        loadRecipe: (_) => throw StateError('unused'),
      ),
    );
    await tester.pumpWidget(
      AppScope(
        services: services,
        child: MaterialApp(
          theme: YinTraceApp.theme(Brightness.light),
          home: SongPage(songId: id),
        ),
      ),
    );
    await _waitFor(tester, () => songGraph.evaluate().isNotEmpty);
  }

  RefToken songToken(WidgetTester tester) =>
      tester.widget<LinePitchGraph>(songGraph).line.tokens.single;

  testWidgets(
    'song chart refreshes when a detached correction finishes saving',
    (tester) async {
      await openSong(tester);
      final songs = services.songs;
      final corrections = services.pitchCorrections;
      expect(songToken(tester).pinned, isNull);

      final finishAlignment = Completer<void>();
      var started = false;
      final session = corrections.attach(
        id,
        () => PitchCorrectionSession(
          songId: id,
          songs: songs,
          retimer: (_, _, _, _, pins) async {
            started = true;
            await finishAlignment.future;
            return _reference(pin: pins[0]);
          },
        ),
      );
      await _waitFor(tester, () => session.reference != null);
      session.setStart(0, 0, 0.8, nudge: true);
      corrections.detach(session);
      expect(started, isFalse);

      await tester.pump(const Duration(milliseconds: 250));
      expect(started, isTrue);
      expect(corrections.busyFor(id), isTrue);
      expect(songToken(tester).pinned, isNull);

      finishAlignment.complete();
      await _waitFor(tester, () => songToken(tester).pinned == 0.8);
      expect(songToken(tester).notes.single.start, 0.8);
      expect(corrections.busyFor(id), isFalse);
      final saved = (await tester.runAsync(() => songs.loadReference(id)))!;
      expect(saved.lines.single.tokens.single.pinned, 0.8);
    },
  );

  testWidgets('a pitch edit during a timing write keeps the saved alignment', (
    tester,
  ) async {
    await openSong(tester, createRepository: _PausingSongRepository.new);
    final songs = services.songs as _PausingSongRepository;
    final corrections = services.pitchCorrections;
    final session = corrections.attach(
      id,
      () => PitchCorrectionSession(
        songId: id,
        songs: songs,
        retimer: (_, _, _, _, pins) async => _reference(pin: pins[0]),
      ),
    );
    await _waitFor(tester, () => session.reference != null);
    final finishWrite = Completer<void>();
    songs.nextWriteGate = finishWrite.future;
    session.setStart(0, 0, 0.8, nudge: false);
    await tester.pump();
    expect(songs.nextWriteGate, isNull);
    expect(corrections.savedRevisionFor(id), 0);

    final pitchEdit = session.changePitch(0, 0, (token) => token.transpose(1));
    corrections.detach(session);
    finishWrite.complete();
    await _waitFor(tester, () => !corrections.busyFor(id));
    await pitchEdit;
    final saved = (await tester.runAsync(() => songs.loadReference(id)))!;
    final token = saved.lines.single.tokens.single;
    expect(corrections.savedRevisionFor(id), 2);
    expect(token.pinned, 0.8);
    expect(token.notes.single.midi, 61);
    await _waitFor(tester, () => songToken(tester).notes.single.midi == 61);
    expect(songToken(tester).pinned, 0.8);
  });

  for (final useModel in [false, true]) {
    final aligner = useModel ? 'HuBERTFA' : 'pitch alignment';
    for (final leaveEditor in [false, true]) {
      final screen = leaveEditor
          ? 'after returning to the song'
          : 'in the editor';
      testWidgets('$aligner rolls back a failed save $screen and can retry', (
        tester,
      ) async {
        tester.view.physicalSize = const Size(390, 844);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        await openSong(tester, useModel: useModel);
        final songs = services.songs;
        final corrections = services.pitchCorrections;
        final file = File(songs.pathFor(id, SongRepository.referenceFile));
        final original = file.readAsStringSync();
        // Fail the actual atomic write, leaving the last saved reference readable.
        final blocked = Directory('${file.path}.tmp')..createSync();
        final finishAlignment = Completer<void>();
        final requested = <double>[];
        final editor = find.byType(PitchEditorPage);
        final editorGraph = find.descendant(
          of: editor,
          matching: find.byWidgetPredicate(
            (w) => w is CustomPaint && w.painter is PitchGraphPainter,
          ),
        );
        PitchGraphPainter preview() =>
            tester.widget<CustomPaint>(editorGraph).painter!
                as PitchGraphPainter;
        RefToken editorToken() =>
            preview().reference!.lines.single.tokens.single;

        Future<PitchCorrectionSession> openEditor() async {
          // The song page attaches to the same session, using the test aligner.
          final session = corrections.attach(
            id,
            () => PitchCorrectionSession(
              songId: id,
              songs: songs,
              retimer: (_, _, _, _, pins) async {
                requested.add(pins[0]!);
                await finishAlignment.future;
                return _reference(pin: pins[0]);
              },
            ),
          );
          await tester.tap(find.byTooltip('校正这一句'));
          await tester.pump();
          await _waitFor(tester, () => editorGraph.evaluate().isNotEmpty);
          await tester.pumpAndSettle();
          corrections.detach(session);
          expect(session.usesHubertFa, useModel);
          return session;
        }

        Future<void> nudge(PitchCorrectionSession session) async {
          session.setStart(0, 0, session.startOf(0, 0) + 0.05, nudge: true);
          await tester.pump();
        }

        var session = await openEditor();
        await nudge(session);
        expect(preview().tokenTimeOffsets[editorToken()], closeTo(0.05, 1e-6));
        expect(requested, isEmpty);
        await tester.pump(const Duration(milliseconds: 250));
        expect(requested.single, closeTo(0.35, 1e-6));
        if (leaveEditor) {
          await tester.binding.handlePopRoute();
          await tester.pumpAndSettle();
          expect(editor, findsNothing);
          expect(songToken(tester).pinned, isNull);
          expect(corrections.busyFor(id), isTrue);
        }

        finishAlignment.complete();
        await _waitFor(tester, () => !corrections.busyFor(id));
        await tester.pumpAndSettle();
        expect(session.failureRevision, 1);
        expect(corrections.savedRevisionFor(id), 0);
        expect(file.readAsStringSync(), original);
        expect(
          find.descendant(
            of: find.byType(SnackBar),
            matching: find.textContaining(
              RegExp(r'^没能保存：.*reference\.json\.tmp'),
            ),
          ),
          findsOneWidget,
        );

        if (leaveEditor) {
          expect(songToken(tester).pinned, isNull);
          final failedSession = session;
          session = await openEditor();
          expect(session, isNot(same(failedSession)));
        }
        expect(editorToken().pinned, isNull);
        expect(editorToken().notes.single.start, 0.3);
        expect(preview().highlight!.$1, 0.3);
        expect(preview().tokenTimeOffsets, isEmpty);

        blocked.deleteSync();
        await nudge(session);
        await tester.pump(const Duration(milliseconds: 250));
        await _waitFor(tester, () => !corrections.busyFor(id));
        expect(requested, hasLength(2));
        expect(requested.last, closeTo(0.35, 1e-6));
        expect(editorToken().pinned, closeTo(0.35, 1e-6));
        expect(corrections.savedRevisionFor(id), 1);
        final saved = (await tester.runAsync(() => songs.loadReference(id)))!;
        expect(saved.lines.single.tokens.single.pinned, closeTo(0.35, 1e-6));

        await tester.tap(find.byType(BackButton));
        await tester.pumpAndSettle();
        await _waitFor(tester, () => songToken(tester).pinned == 0.35);
        expect(songToken(tester).notes.single.start, 0.35);
      });
    }
  }
}
