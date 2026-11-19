import 'dart:async';
import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/import/import_job.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/import/import_queue.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace/src/library/song.dart';
import 'package:yintrace/src/library/song_repository.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace/src/ui/import_queue_page.dart';
import 'package:yintrace/src/ui/song_page.dart';

final class _PickedFile extends PlatformFile {
  _PickedFile(this.file);

  final File file;

  @override
  String get name => uri.pathSegments.last;
  @override
  Uri get uri => file.uri;
  @override
  Never get xFile => throw UnimplementedError();
  @override
  int? lengthSync() => file.lengthSync();
  @override
  Future<int?> length() => file.length();
  @override
  Future<Uint8List> readAsBytes() => file.readAsBytes();
  @override
  Stream<Uint8List> readAsByteStream() => file.openRead().map(Uint8List.fromList);
}

class _AudioPicker extends FilePickerPlatform {
  _AudioPicker(this.paths);

  final List<File> paths;

  @override
  Future<PlatformFile?> pickFile({
    String? dialogTitle,
    String? initialDirectory,
    FileType type = FileType.any,
    List<String>? allowedExtensions,
    Function(FilePickerStatus)? onFileLoading,
    int compressionQuality = 0,
    AndroidOptions androidOptions = const AndroidOptions(),
    DarwinOptions darwinOptions = const DarwinOptions(),
    WindowsOptions windowsOptions = const WindowsOptions(),
    LinuxOptions linuxOptions = const LinuxOptions(),
    WebOptions webOptions = const WebOptions(),
  }) async => _PickedFile(paths.removeAt(0));
}

const _lyrics = '[00:00.00]春风';

Future<SongMeta> _saveSong(SongRepository repo, String title) async {
  final song = SongMeta(
    id: repo.newSongId(),
    title: title,
    createdAt: DateTime.now(),
    duration: 2,
    lyrics: _lyrics,
    vocalsFile: 'vocals.wav',
  );
  await repo.saveReference(song.id, SongReference(lines: [], duration: 2));
  await repo.savePitchTrack(
    song.id,
    PitchTrack(
      hopSeconds: 0.01,
      midi: Float32List(0),
      rmsDb: Float32List(0),
      aperiodicity: Float32List(0),
    ),
  );
  await repo.save(song);
  return song;
}

void main() {
  testWidgets(
    'queues more audio while importing, lets the library stay open, and refreshes it on completion',
    (tester) async {
      final temp = Directory.systemTemp.createTempSync('yt-queue-ui');
      final pickerRoot = Directory(
        '${Directory.systemTemp.path}/flutter_file_picker',
      )..createSync(recursive: true);
      File pick(String name) =>
          File('${pickerRoot.createTempSync('queue-test-').path}/$name.wav')
            ..writeAsStringSync(name);
      final firstInput = pick('春天');
      final secondInput = pick('山谷');
      final originalPicker = FilePickerPlatform.instance;
      FilePickerPlatform.instance = _AudioPicker([firstInput, secondInput]);
      addTearDown(() {
        FilePickerPlatform.instance = originalPicker;
        for (final dir in [firstInput.parent, secondInput.parent, temp]) {
          if (dir.existsSync()) dir.deleteSync(recursive: true);
        }
      });

      final repo = SongRepository(Directory('${temp.path}/songs'));
      final existing = (await tester.runAsync(() => _saveSong(repo, '旧歌')))!;
      final events = <String, StreamController<ImportEvent>>{};
      final queue = ImportQueue(
        repo.root.path,
        VocalAcceleration.unavailable(),
        startAudio: (request) async {
          final stream = events[request.title] =
              StreamController<ImportEvent>();
          return (events: stream.stream, cancel: () async {});
        },
      );
      final services = AppServices(
        settings: AppSettings(null),
        songs: repo,
        models: ModelManager(
          dir: Directory('${temp.path}/models'),
          loadRecipe: (_) => throw StateError('unused'),
        ),
        importQueue: queue,
      );
      addTearDown(queue.dispose);

      Future<void> waitFor(Finder finder) async {
        for (
          var attempt = 0;
          attempt < 30 && finder.evaluate().isEmpty;
          attempt++
        ) {
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 20)),
          );
          await tester.pump(const Duration(milliseconds: 40));
        }
        expect(finder, findsOneWidget);
      }

      Future<void> addAudio(String button) async {
        await tester.tap(find.text(button));
        await tester.pumpAndSettle();
        await tester.tap(find.text('整首歌，mp3、m4a、wav 或 flac'));
        await tester.pump();
        await tester.tap(find.text('这是已经分离好的纯人声'));
        await tester.pumpAndSettle();
        await tester.scrollUntilVisible(
          find.text('从文件读取 .lrc'),
          200,
          scrollable: find.byType(Scrollable).first,
        );
        await tester.pump();
        await tester.enterText(find.byType(TextField).last, _lyrics);
        await tester.pump();
        await tester.tap(find.widgetWithText(FilledButton, '生成逐字音高图'));
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 500));
      }

      await tester.pumpWidget(
        AppScope(services: services, child: const YinTraceApp()),
      );
      await waitFor(find.text('旧歌'));
      await addAudio('导入歌曲');
      events['春天']!.add(
        ImportProgressEvent(
          const ImportProgress(ImportStage.analyzingPitch, 0.3, 0.3),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.byType(ImportQueuePage), findsOneWidget);
      expect(find.text('测量音高 · 30%'), findsOneWidget);
      expect(
        firstInput.existsSync(),
        isTrue,
        reason: 'the disposed form handed off its picker copy',
      );

      await addAudio('继续导入歌曲');
      events['山谷']!.add(
        ImportProgressEvent(
          const ImportProgress(ImportStage.aligning, 0.7, 0.7),
        ),
      );
      await tester.pumpAndSettle();
      expect(find.text('测量音高 · 30%'), findsOneWidget);
      expect(find.text('逐句对齐歌词 · 70%'), findsOneWidget);
      expect(secondInput.existsSync(), isTrue);

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await tester.tap(find.text('旧歌'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await waitFor(find.text('旧歌'));
      expect(
        tester.widget<SongPage>(find.byType(SongPage)).songId,
        existing.id,
      );
      expect(queue.activeCount, 2);
      final first = (await tester.runAsync(() => _saveSong(repo, '春天')))!;
      events['春天']!.add(ImportDoneEvent(first));
      unawaited(events['春天']!.close());
      await tester.pump();
      expect(
        tester.widget<SongPage>(find.byType(SongPage)).songId,
        existing.id,
      );

      await tester.tap(find.byType(BackButton));
      await tester.pumpAndSettle();
      await waitFor(find.text('春天'));
      expect(find.text('山谷'), findsNothing);
      final second = (await tester.runAsync(() => _saveSong(repo, '山谷')))!;
      events['山谷']!.add(ImportDoneEvent(second));
      unawaited(events['山谷']!.close());
      await tester.pump();
      await waitFor(find.text('山谷'));
      expect(queue.activeCount, 0);
      expect(firstInput.existsSync(), isFalse);
      expect(secondInput.existsSync(), isFalse);
    },
    variant: TargetPlatformVariant.only(TargetPlatform.iOS),
  );
}
