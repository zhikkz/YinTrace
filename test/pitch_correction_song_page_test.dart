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

void main() {
  testWidgets(
    'song chart refreshes when a detached correction finishes saving',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('yt-correction-refresh');
      addTearDown(() => temp.deleteSync(recursive: true));
      final songs = SongRepository(Directory('${temp.path}/songs'));
      final id = songs.newSongId();
      await tester.runAsync(() async {
        await songs.save(
          SongMeta(
            id: id,
            title: '春风',
            createdAt: DateTime(2026),
            duration: 2,
            lyrics: '[00:00.30]春',
            vocalsFile: 'vocals.wav',
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
      final services = AppServices(
        settings: AppSettings(null),
        songs: songs,
        models: ModelManager(
          dir: Directory('${temp.path}/models'),
          loadRecipe: (_) => throw StateError('unused'),
        ),
      );
      final corrections = services.pitchCorrections;
      final graph = find.byType(LinePitchGraph);
      RefToken shownToken() =>
          tester.widget<LinePitchGraph>(graph).line.tokens.single;

      Future<void> waitFor(bool Function() ready) async {
        for (var attempt = 0; attempt < 40 && !ready(); attempt++) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump();
        }
        expect(ready(), isTrue);
      }

      await tester.pumpWidget(
        AppScope(
          services: services,
          child: MaterialApp(
            theme: YinTraceApp.theme(Brightness.light),
            home: SongPage(songId: id),
          ),
        ),
      );
      await waitFor(() => graph.evaluate().isNotEmpty);
      expect(shownToken().pinned, isNull);

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
      await waitFor(() => session.reference != null);
      session.setStart(0, 0, 0.8, nudge: true);
      corrections.detach(session);
      expect(started, isFalse);

      await tester.pump(const Duration(milliseconds: 250));
      expect(started, isTrue);
      expect(corrections.busyFor(id), isTrue);
      expect(shownToken().pinned, isNull);

      finishAlignment.complete();
      await waitFor(() => shownToken().pinned == 0.8);
      expect(shownToken().notes.single.start, 0.8);
      expect(corrections.busyFor(id), isFalse);
      final saved = (await tester.runAsync(() => songs.loadReference(id)))!;
      expect(saved.lines.single.tokens.single.pinned, 0.8);
    },
  );
}
