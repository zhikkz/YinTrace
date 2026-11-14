// Host-side tests for the Dart bindings. They need the native library built
// for the host; tool/run_dart_tests.sh builds it and sets YINTRACE_AUDIO_LIB.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

void main() {
  final lib = Platform.environment['YINTRACE_AUDIO_LIB'];
  final skip = (lib == null || lib.isEmpty)
      ? 'YINTRACE_AUDIO_LIB not set (run tool/run_dart_tests.sh)'
      : null;

  test('library loads', () {
    expect(NativeAudio.isAvailable, isTrue);
    expect(NativeAudio.micPermission, MicPermission.granted);
  }, skip: skip);

  test('device facts are unknown off Apple platforms', () {
    // The host library is built for Linux in CI.
    expect(NativeAudio.availableMemory, isNull);
    expect(NativeAudio.deviceModel, isNull);
    expect(NativeAudio.physicalMemory, isNull);
    expect(NativeAudio.thermalState, isNull);
  }, skip: skip ?? (Platform.isLinux ? null : 'Linux host only'));

  test('audio event log keeps the latest lines, oldest first', () {
    for (var i = 0; i < 30; i++) {
      NativeAudio.logAudioEvent('app: 第 $i 行');
    }
    final log = NativeAudio.audioEventLog;
    expect(log.length, 24);
    expect(log.first, 'app: 第 6 行');
    expect(log.last, 'app: 第 29 行');
    NativeAudio.logAudioEvent('音' * 80); // longer than a line: cut, still valid text
    expect(NativeAudio.audioEventLog.last, '音' * 37);
  }, skip: skip);

  test('route changes keep playing, a lost output silences', () {
    final e = PracticeEngine.create(mode: EngineMode.offline);
    e.loadTrackPcm(0, Float32List.fromList(List.filled(4096 * 2, 0.25)), 2);
    e.play();
    e.render(256);
    e.signalAudioEvent(AudioEvents.routeChanged);
    expect(e.isPlaying, isTrue);
    expect(e.render(256)[0], closeTo(0.25, 1e-3));
    e.signalAudioEvent(AudioEvents.deviceLost);
    expect(e.isPlaying, isFalse);
    expect(e.render(256)[0], 0);
    expect(e.takeAudioEvents(), AudioEvents.routeChanged | AudioEvents.deviceLost);
    e.dispose();
  }, skip: skip);

  test('offline engine renders tracks and tags capture', () {
    final e = PracticeEngine.create(mode: EngineMode.offline);
    addTearDown(e.dispose);
    final track = Float32List(44100);
    for (var i = 0; i < track.length; i++) {
      track[i] = 0.5 * math.sin(2 * math.pi * 220 * i / 44100);
    }
    e.loadTrackPcm(0, track, 1);
    expect(e.lengthFrames, 44100);
    e.seek(const Duration(milliseconds: 500));
    e.play();
    final mic = Float32List(512)..fillRange(0, 512, 0.1);
    final out = e.render(512, input: mic);
    expect(out.length, 1024);
    expect((out[0] - track[22050]).abs(), lessThan(1e-3));
    final blocks = e.readCapture();
    expect(blocks, hasLength(1));
    expect(blocks.first.songFrame, 22050);
    expect(blocks.first.playing, isTrue);
    expect(blocks.first.samples[3], closeTo(0.1, 1e-6));
    expect(e.positionFrame, 22050 + 512);

    e.setLoop(0.5, 0.51);
    e.render(1000, input: Float32List(1000));
    final looped = e.readCapture();
    expect(looped.length, greaterThan(1));
    expect(looped[1].songFrame, 22050);
  }, skip: skip);

  test('decode wav written by ffmpeg', () {
    final path = Platform.environment['YINTRACE_TEST_WAV'];
    if (path == null) return;
    final audio = NativeAudio.decodeFile(path, sampleRate: 22050, channels: 1);
    expect(audio.channels, 1);
    expect(audio.duration, closeTo(3.0, 0.1));
    expect(() => NativeAudio.decodeFile('/nonexistent.wav'),
        throwsA(isA<NativeAudioException>()));
  }, skip: skip);
}
