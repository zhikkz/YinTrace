// Settings on disk: changes in quick succession (a slider being dragged)
// must leave a readable file with the last value.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/atomic_file.dart';
import 'package:yintrace/src/app/settings.dart';
import 'package:yintrace/src/import/vocal_acceleration.dart';
import 'package:yintrace_audio/yintrace_audio.dart' show OutputRoute, PracticeEngine;

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
    expect(s.autoCheckUpdates, isTrue, reason: 'checks for updates unless turned off');
    await s.update((x) => x
      ..octaveTolerant = false
      ..autoCheckUpdates = false);
    final loaded = await AppSettings.load(file);
    expect([loaded.latencyOffsetMs, loaded.octaveTolerant, loaded.autoCheckUpdates], [180, false, false]);
    // No file (tests, previews): nothing to do, nothing thrown.
    await AppSettings(null).update((x) => x.toleranceCents = 30);
  });

  test('latency settings keep the old fallback and save offsets by route and mode', () async {
    final file = File('${tmp.path}/settings.json')..writeAsStringSync('{"latencyOffsetMs": 123}');
    final s = await AppSettings.load(file);
    for (final route in OutputRoute.values) {
      expect(s.latencyOffsetFor(route, measurement: false), 123);
      expect(s.latencyOffsetFor(route, measurement: true), 123);
    }

    const offsets = {
      OutputRoute.speaker: -8,
      OutputRoute.wired: 4,
      OutputRoute.usb: 9,
      OutputRoute.bluetooth: 407,
      OutputRoute.airPlay: 685,
    };
    await s.update((s) {
      for (final entry in offsets.entries) {
        s.setLatencyOffset(entry.key, entry.value, measurement: false);
      }
      s.setLatencyOffset(OutputRoute.wired, -12, measurement: true);
    });

    final loaded = await AppSettings.load(file);
    expect(loaded.latencyOffsetMs, 123);
    expect(loaded.latencyOffsetFor(OutputRoute.unknown, measurement: false), 123);
    for (final entry in offsets.entries) {
      expect(loaded.latencyOffsetFor(entry.key, measurement: false), entry.value);
    }
    expect(loaded.latencyOffsetFor(OutputRoute.wired, measurement: true), -12);
    expect(loaded.latencyOffsetFor(OutputRoute.bluetooth, measurement: true), 123);
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
    expect(settings.monitorLevel, 0.5);
    await settings.update((s) => s.monitorLevel = 0.3);
    expect((await AppSettings.load(file)).monitorLevel, 0.3);
    expect(settings.toJson().containsKey('monitorEnabled'), isFalse);
    expect(settings.toJson().containsKey('monitorVolume'), isFalse);
    for (final (stored, expected) in [(2, 1.0), (-1, 0.0)]) {
      file.writeAsStringSync(jsonEncode({'monitorLevel': stored}));
      expect((await AppSettings.load(file)).monitorLevel, expected);
    }
    // The old linear volume is not carried over: pushed to the top to hear
    // the old, quiet monitor, it would now mean +24 dB.
    file.writeAsStringSync(jsonEncode({'monitorVolume': 1.0}));
    expect((await AppSettings.load(file)).monitorLevel, 0.5);
  });

  test('the monitor level maps to a gain with a square taper', () {
    final s = AppSettings(null);
    double gainAt(double level) => (s..monitorLevel = level).monitorGain;
    expect(gainAt(0), 0);
    expect(gainAt(0.25), closeTo(1, 1e-12)); // unity, the old maximum
    expect(gainAt(0.5), closeTo(4, 1e-12)); // +12 dB, the default
    expect(gainAt(0.75), closeTo(9, 1e-12));
    expect(gainAt(1), PracticeEngine.maxMonitorGain); // +24 dB
    expect(gainAt(2), PracticeEngine.maxMonitorGain);
    expect(gainAt(double.nan), 0);
    for (var v = 0.0; v < 1; v += 0.01) {
      expect(gainAt(v + 0.01), greaterThan(gainAt(v)));
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
