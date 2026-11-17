// Settings on disk: changes in quick succession (a slider being dragged)
// must leave a readable file with the last value.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/atomic_file.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';

void main() {
  late Directory tmp;
  setUp(() => tmp = Directory.systemTemp.createTempSync('yt_settings'));
  tearDown(() => tmp.deleteSync(recursive: true));

  test('rapid updates leave a readable settings file with the last value', () async {
    final file = File('${tmp.path}/settings.json');
    var corrupt = 0, stale = 0;
    final rng = math.Random(7);
    for (var round = 0; round < 300; round++) {
      final s = AppSettings(file);
      final pending = <Future<void>>[];
      for (var i = 0, n = 2 + rng.nextInt(6); i < n; i++) {
        // Values whose JSON text has different lengths, like a slider's.
        final v = i.isEven ? -25 - rng.nextDouble() * 45 : (-25 - rng.nextInt(45)).toDouble();
        pending.add(s.update((x) => x.micGateDb = v));
        if (rng.nextBool()) await Future<void>.delayed(Duration.zero);
      }
      await Future.wait(pending);
      try {
        final j = jsonDecode(await file.readAsString()) as Map<String, dynamic>;
        if ((j['micGateDb'] as num).toDouble() != s.micGateDb) stale++;
      } catch (_) {
        corrupt++;
      }
    }
    expect([corrupt, stale], [0, 0]);
    expect(tmp.listSync().map((f) => f.path.split('/').last), ['settings.json'], reason: 'no temporary file left');
  });

  test('settings survive a restart; a dragged value is saved when it is let go', () async {
    final file = File('${tmp.path}/sub/settings.json');
    final s = AppSettings(file);
    var notified = 0;
    s.addListener(() => notified++);
    s.change((x) => x.latencyOffsetMs = 120); // dragging
    s.change((x) => x.latencyOffsetMs = 180);
    expect(notified, 2);
    expect(file.existsSync(), isFalse, reason: 'nothing written while dragging');
    await s.save(); // let go
    expect((await AppSettings.load(file)).latencyOffsetMs, 180);
    await s.update((x) => x.octaveTolerant = false);
    final loaded = await AppSettings.load(file);
    expect([loaded.latencyOffsetMs, loaded.octaveTolerant], [180, false]);
    // No file (tests, previews): nothing to do, nothing thrown.
    await AppSettings(null).update((x) => x.toleranceCents = 30);
  });

  test('a writer writes the newest state once, not every state in between', () async {
    final file = File('${tmp.path}/state.txt');
    var value = 0, reads = 0;
    final writer = LatestStateWriter(file, () {
      reads++;
      return '$value';
    });
    final saves = [
      for (var i = 1; i <= 50; i++)
        () {
          value = i;
          return writer.save();
        }(),
    ];
    await Future.wait(saves);
    expect(file.readAsStringSync(), '50');
    expect(reads, lessThanOrEqualTo(2), reason: 'the write in flight, then the newest state');
    value = 51;
    await writer.save();
    expect(file.readAsStringSync(), '51', reason: 'a save after the queue ran dry starts a new write');
  });

  test('monitor level persists with safe defaults for old or out-of-range settings', () async {
    final file = File('${tmp.path}/monitor.json')..writeAsStringSync('{}');
    final settings = await AppSettings.load(file);
    expect(settings.monitorVolume, 0.5);
    await settings.update((s) => s.monitorVolume = 0.3);
    expect((await AppSettings.load(file)).monitorVolume, 0.3);
    expect(settings.toJson().containsKey('monitorEnabled'), isFalse);
    for (final (stored, expected) in [(2, 1.0), (-1, 0.0)]) {
      file.writeAsStringSync(jsonEncode({'monitorVolume': stored}));
      expect((await AppSettings.load(file)).monitorVolume, expected);
    }
  });

  test('a failed write is reported and the next one works', () async {
    final blocker = File('${tmp.path}/dir')..writeAsStringSync('a file where the directory should be');
    final writer = LatestStateWriter(File('${blocker.path}/state.txt'), () => 'x');
    await expectLater(writer.save(), throwsA(isA<FileSystemException>()));
    blocker.deleteSync();
    await writer.save();
    expect(File('${tmp.path}/dir/state.txt').readAsStringSync(), 'x');
  });

  test('the acceleration state is written the same way', () async {
    final a = VocalAcceleration(tmp, supported: true);
    await Future.wait([for (var i = 0; i < 20; i++) a.setEnabled(i.isOdd)]);
    final loaded = await VocalAcceleration.load(tmp, supported: true);
    expect(loaded.userEnabled, isTrue);
    expect(tmp.listSync().map((f) => f.path.split('/').last), ['acceleration.json']);
  });
}
