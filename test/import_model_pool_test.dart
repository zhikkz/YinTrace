import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/import/import_model_pool.dart';
import 'package:yintrace/src/separation/tensor_model.dart';

void main() {
  test('exclusive stage reuses its model, releases canceled jobs and evicts before switching', () async {
    final pool = ImportModelPool();
    final operations = <String>[];
    final releaseFirst = Completer<void>();
    final firstStarted = Completer<void>();

    Future<void> use(
      String job,
      String model, {
      bool overlap = false,
      bool Function()? isCancelled,
      Future<void> Function()? work,
    }) => pool.use(
      model,
      load: () async {
        operations.add('open $model');
        return model;
      },
      close: (model) async => operations.add('close $model'),
      run: (_) async {
        operations.add(job);
        await work?.call();
      },
      isCancelled: isCancelled,
      canOverlap: () => overlap,
    );

    final first = use(
      'song A',
      'vocal',
      work: () {
        firstStarted.complete();
        return releaseFirst.future;
      },
    );
    await firstStarted.future;

    var cancelled = false;
    final waiting = use('song C', 'pitch', isCancelled: () => cancelled);
    final cancellation = expectLater(
      waiting,
      throwsA(isA<SeparationCancelled>()),
    );
    final different = use('song D', 'alignment');
    final matching = use('song B', 'vocal', overlap: true);
    await Future<void>.delayed(Duration.zero);
    expect(operations, ['open vocal', 'song A']);

    cancelled = true;
    pool.cancelPending();
    await cancellation;
    releaseFirst.complete();
    await Future.wait([first, matching, different]);
    await pool.close();
    expect(operations, [
      'open vocal',
      'song A',
      'song B',
      'close vocal',
      'open alignment',
      'song D',
      'close alignment',
    ]);
  });
}
