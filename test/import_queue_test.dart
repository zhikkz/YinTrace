import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/import/import_job.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/import/import_queue.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace/src/library/song.dart';

class _Task {
  final controller = StreamController<ImportEvent>();
  var cancellations = 0;

  ImportTask get handle =>
      (events: controller.stream, cancel: () async => cancellations++);
}

ImportRequest _request(String title) => ImportRequest(
  title: title,
  audioPath: '/test/$title.wav',
  lyrics: '[00:00.00]春风',
  vocalsOnly: true,
);

SongMeta _song(String title) => SongMeta(
  id: title,
  title: title,
  createdAt: DateTime(2026),
  duration: 2,
  lyrics: '[00:00.00]春风',
  vocalsFile: 'vocals.m4a',
);

Future<void> _settle() => Future<void>.delayed(Duration.zero);

void main() {
  test('runs two songs with independent progress and advances the waiting songs in order', () async {
    final tasks = <String, _Task>{};
    final queue = ImportQueue(
      '/test/songs',
      VocalAcceleration.unavailable(),
      startAudio: (request) async {
        return (tasks[request.title] = _Task()).handle;
      },
    );
    addTearDown(queue.dispose);
    for (final title in ['first', 'second', 'third', 'fourth']) {
      queue.enqueue(_request(title));
    }
    final [fourth, third, second, first] = queue.entries.toList();
    expect(queue.activeCount, 4);
    expect(tasks.keys, ['first', 'second']);
    expect(
      [third.status, fourth.status],
      [ImportQueueStatus.queued, ImportQueueStatus.queued],
    );

    tasks['first']!.controller.add(
      ImportProgressEvent(
        const ImportProgress(ImportStage.analyzingPitch, 0.5, 0.4),
      ),
    );
    tasks['second']!.controller.add(
      ImportProgressEvent(const ImportProgress(ImportStage.aligning, 0.3, 0.8)),
    );
    await _settle();
    expect(first.progress?.overall, 0.4);
    expect(second.progress?.overall, 0.8);

    tasks['second']!.controller.add(ImportDoneEvent(_song('second')));
    await tasks['second']!.controller.close();
    await _settle();
    expect(second.status, ImportQueueStatus.completed);
    expect(second.song?.id, 'second');
    expect(first.status, ImportQueueStatus.running);
    expect(queue.completedCount, 1);
    expect(tasks.keys, ['first', 'second', 'third']);

    await queue.cancel(fourth);
    expect(fourth.status, ImportQueueStatus.cancelled);
    expect(tasks.containsKey('fourth'), isFalse);
    await queue.cancel(first);
    expect(first.status, ImportQueueStatus.cancelling);
    expect(tasks['first']!.cancellations, 1);
    tasks['first']!.controller.add(ImportFailedEvent('已取消', cancelled: true));
    await tasks['first']!.controller.close();
    tasks['third']!.controller.add(ImportFailedEvent('无法读取音频'));
    await tasks['third']!.controller.close();
    await _settle();
    expect(first.status, ImportQueueStatus.cancelled);
    expect(third.status, ImportQueueStatus.failed);
    expect(third.error, '无法读取音频');
    expect(queue.activeCount, 0);
    expect(queue.completedCount, 1);
  });

  test('cancels an import while its worker is starting', () async {
    final starting = Completer<ImportTask>();
    final queue = ImportQueue(
      '/test/songs',
      VocalAcceleration.unavailable(),
      startAudio: (_) => starting.future,
    );
    addTearDown(queue.dispose);
    queue.enqueue(_request('song'));
    final entry = queue.entries.single;
    await queue.cancel(entry);
    expect(entry.status, ImportQueueStatus.cancelling);

    final task = _Task();
    starting.complete(task.handle);
    await _settle();
    expect(task.cancellations, 1);
    task.controller.add(ImportFailedEvent('已取消', cancelled: true));
    await task.controller.close();
    await _settle();
    expect(entry.status, ImportQueueStatus.cancelled);
    expect(queue.activeCount, 0);
  });

  test('an overlapping import preserves the first running import’s Core ML trial marker', () async {
    final dir = Directory.systemTemp.createTempSync('yt_queue');
    addTearDown(() => dir.deleteSync(recursive: true));
    final acceleration = VocalAcceleration(dir, supported: true);
    addTearDown(acceleration.dispose);
    final model = File('${dir.path}/model.onnx')..writeAsStringSync('fake');
    final tasks = <_Task>[];
    final began = StreamController<ImportRequest>();
    final requests = StreamIterator(began.stream);
    addTearDown(began.close);
    addTearDown(requests.cancel);
    final queue = ImportQueue(
      '/test/songs',
      acceleration,
      startAudio: (request) async {
        began.add(request);
        final task = _Task();
        tasks.add(task);
        return task.handle;
      },
    );
    addTearDown(queue.dispose);
    void enqueue(String title) => queue.enqueue(
      ImportRequest(
        title: title,
        audioPath: '/test/$title.wav',
        lyrics: '[00:00.00]春风',
        mdxModelPath: model.path,
      ),
    );

    enqueue('first');
    expect(await requests.moveNext(), isTrue);
    final marker = File(requests.current.coreMLMarker!)
      ..writeAsStringSync('first still running');
    enqueue('second');
    expect(await requests.moveNext(), isTrue);
    expect(requests.current.mdxCoreML, isNotNull);
    expect(marker.readAsStringSync(), 'first still running');
    expect(acceleration.disabledReason, isNull);

    for (final task in tasks) {
      task.controller.add(ImportFailedEvent('已取消', cancelled: true));
      await task.controller.close();
    }
    await _settle();
    expect(queue.activeCount, 0);
  });
}
