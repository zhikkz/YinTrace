// Real Apple-plugin smoke test; run by CI on an iOS simulator.
// Downloads only the two official UVR files at runtime. No model weights or
// user audio/lyrics are bundled with this test.
import 'dart:io';
import 'dart:convert';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:yintrace/src/app/licenses.dart';
import 'package:yintrace/src/app/services.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/separation/model_config.dart';
import 'package:yintrace/src/separation/onnx_model.dart';
import 'package:yintrace/src/ui/app.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Apple native audio, bundled AGPL, real ONNX sessions without arena', (tester) async {
    final services = await AppServices.init();
    registerThirdPartyLicenses();
    await tester.pumpWidget(AppScope(services: services, child: const YinTraceApp()));
    await tester.pumpAndSettle();
    expect(NativeAudio.isAvailable, isTrue);
    final engine = PracticeEngine.create(mode: EngineMode.duplex, nullBackend: true);
    engine.start();
    engine.stop();
    engine.dispose();

    // Core Audio encode/decode is exercised on the actual iOS build.
    final tmp = Directory.systemTemp.createTempSync('yintrace_smoke');
    try {
      final samples = Float32List(44100);
      for (var i = 0; i < samples.length; i++) {
        samples[i] = 0.2 * math.sin(2 * math.pi * 220 * i / 44100);
      }
      final path = '${tmp.path}/tone.m4a';
      expect(NativeAudio.encodeM4a(path, samples, 44100, 1), isTrue);
      final decoded = NativeAudio.decodeFile(path, channels: 1);
      expect(decoded.duration, closeTo(1, 0.1));

      // TestWidgetsFlutterBinding intentionally omits ServicesBinding's
      // automatic license loader. Read the same on-device asset that the
      // normal app binding displays on LicensePage, rather than assuming the
      // integration harness registered it.
      final notices = await rootBundle.load('NOTICES.Z');
      final licenseText = utf8.decode(gzip.decode(notices.buffer.asUint8List()));
      expect(licenseText, contains('GNU AFFERO GENERAL PUBLIC LICENSE'));
      expect(licenseText, contains('Version 3, 19 November 2007'));
      final entries = await LicenseRegistry.licenses.toList();
      expect(entries.any((e) => e.packages.contains('Ultimate Vocal Remover GUI')), isTrue);
      // ignore: avoid_print
      print('iOS simulator: native audio, AAC and bundled AGPL OK; downloading models');

      await services.models.install();
      expect(services.models.error, isNull);
      expect(services.models.isReady, isTrue);
      // ignore: avoid_print
      print('iOS simulator: both models installed');
      for (final pair in [
        (vocalModel, MdxConfig.vocFt.inputShape),
        (karaokeModel, VrConfig.karaoke6Hp.inputShape),
      ]) {
        final model = await OnnxTensorModel.load(services.models.pathFor(pair.$1)!);
        final input = Float32List(pair.$2.reduce((a, b) => a * b));
        for (var i = 0; i < input.length; i++) {
          input[i] = (i % 101) / 101;
        }
        try {
          final watch = Stopwatch()..start();
          for (var run = 0; run < 3; run++) {
            final out = await model.run(input, pair.$2);
            expect(out.length, input.length);
            expect(out.every((v) => v.isFinite), isTrue);
          }
          // ignore: avoid_print
          print(
            'iOS simulator ${pair.$1.id}: 3 runs ${watch.elapsedMilliseconds} ms; '
            'process peak ${ProcessInfo.maxRss / 1e6} MB',
          );
        } finally {
          await model.close();
        }
      }
      // An isolated session peak is a regression gate, not a device guarantee
      // for a complete import; long-song/device profiling is still required.
      expect(ProcessInfo.maxRss, lessThan(1500000000));
    } finally {
      tmp.deleteSync(recursive: true);
    }
  }, timeout: const Timeout(Duration(minutes: 30)));
}
