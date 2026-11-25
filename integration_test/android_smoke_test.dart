// Android smoke test; run by CI on an emulator (see the android job in
// .github/workflows/ci.yml), where tools/ci_android_allow_microphone.py taps
// "Allow" on the system microphone prompt this test raises.
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import 'android_fixtures.dart';

/// The first frame of channel 0 louder than the silence before the tone.
int _onset(DecodedAudio audio) {
  for (var i = 0; i < audio.frames; i++) {
    if (audio.samples[i * audio.channels].abs() > 0.05) return i;
  }
  return -1;
}

/// The tone's frequency from its zero crossings between [from] and [to] s.
double _frequency(DecodedAudio audio, double from, double to) {
  final start = (from * audio.sampleRate).round();
  final end = (to * audio.sampleRate).round();
  var crossings = 0;
  for (var i = start + 1; i < end; i++) {
    final a = audio.samples[(i - 1) * audio.channels], b = audio.samples[i * audio.channels];
    if ((a < 0) != (b < 0)) crossings++;
  }
  return crossings / 2 / (to - from);
}

File _write(Directory dir, String name, String base64Data) =>
    File('${dir.path}/$name')..writeAsBytesSync(base64Decode(base64Data));

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  test('AAC in M4A and ADTS decodes with the encoder delay trimmed; WAV still decodes', () {
    expect(NativeAudio.isAvailable, isTrue);
    final tmp = Directory.systemTemp.createTempSync('yintrace_android');
    try {
      final m4a = _write(tmp, 'onset.m4a', onsetM4a);
      final stereo = NativeAudio.decodeFile(m4a.path, sampleRate: 44100, channels: 2);
      // ignore: avoid_print
      print('Android m4a 44.1 kHz stereo: ${stereo.frames} frames, onset at frame ${_onset(stereo)}');
      // ignore: avoid_print
      print(NativeAudio.audioEventLog.join('\n'));
      // 1.5 s as the edit list says: no priming before, no padding after.
      expect(stereo.frames, inInclusiveRange(66150 - 2, 66150 + 2));
      expect(_onset(stereo) / 44100, closeTo(0.5, 0.01));
      expect(_frequency(stereo, 0.6, 1.4), closeTo(440, 5));
      for (var i = 0; i < stereo.frames; i += 997) {
        expect(stereo.samples[2 * i + 1], closeTo(stereo.samples[2 * i], 0.02));
      }

      // Resampled and mixed down by the same path as practice and import.
      final mono = NativeAudio.decodeFile(m4a.path, sampleRate: 48000, channels: 1);
      expect(mono.frames, inInclusiveRange(72000 - 2, 72000 + 2));
      expect(_onset(mono) / 48000, closeTo(0.5, 0.01));
      expect(_frequency(mono, 0.6, 1.4), closeTo(440, 5));

      // ADTS has no edit list; only the length and the tone are checked.
      final adts = NativeAudio.decodeFile(_write(tmp, 'tone.aac', toneAac).path, sampleRate: 48000, channels: 2);
      // ignore: avoid_print
      print('Android aac (ADTS) 48 kHz: ${adts.frames} frames');
      expect(adts.frames, inInclusiveRange(24000 - 64, 24000 + 3072));
      expect(_frequency(adts, 0.1, 0.4), closeTo(660, 7));

      // WAV stays with miniaudio.
      final tone = Float32List(22050);
      for (var i = 0; i < tone.length; i++) {
        tone[i] = 0.5 * math.sin(2 * math.pi * 330 * i / 44100);
      }
      final wav = '${tmp.path}/tone.wav';
      writeWavFile(wav, tone, 1, 44100);
      final decoded = NativeAudio.decodeFile(wav, sampleRate: 44100, channels: 1);
      expect(decoded.frames, 22050);
      expect(decoded.samples[1234], closeTo(tone[1234], 1e-4));

      expect(() => NativeAudio.decodeFile(_write(tmp, 'bad.m4a', base64Encode(utf8.encode('....ftypM4A not audio'))).path),
          throwsA(isA<NativeAudioException>()));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  });

  testWidgets('the microphone is asked for at run time', (tester) async {
    expect(Platform.isAndroid, isTrue);
    expect(() => NativeAudio.micPermission, throwsUnsupportedError);
    // A fresh install has not been asked yet.
    expect(await NativeAudio.checkMicPermission(), MicPermission.undetermined);
    final answer = await NativeAudio.requestMicPermission(timeout: const Duration(minutes: 2));
    expect(answer, MicPermission.granted);
    expect(await NativeAudio.checkMicPermission(), MicPermission.granted);
    // Granted: answered at once, without a prompt.
    expect(await NativeAudio.requestMicPermission(timeout: const Duration(seconds: 5)), MicPermission.granted);
  }, timeout: const Timeout(Duration(minutes: 4)));
}
