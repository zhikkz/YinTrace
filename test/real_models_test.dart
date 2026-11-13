// The app's Dart separation code driven by the real UVR models, compared
// with what UVR's own Python code produces for the same clip.
//
// Opt-in, because it needs the models and a Python with onnxruntime:
//
//   tools/fetch_models.sh build/uvr-models
//   python tools/reference/make_real_reference.py --uvr <uvr checkout> \
//       --models build/uvr-models --audio song.wav --out build/real-reference
//   MODELS_DIR=$PWD/build/uvr-models REAL_REFERENCE=$PWD/build/real-reference \
//       flutter test test/real_models_test.dart
//
// PYTHON selects the interpreter (default python3). REAL_OUT keeps the
// Dart results as WAV files.
import 'dart:io';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/models/model_recipe.dart';
import 'package:yintrace/src/separation/mdx_separator.dart';
import 'package:yintrace/src/separation/model_config.dart';
import 'package:yintrace/src/separation/vr_separator.dart';

import 'support/python_ort_model.dart';

/// Signal-to-difference ratio of [x] against [reference] in dB.
double snr(Float32List x, Float32List reference) {
  final n = math.min(x.length, reference.length);
  var err = 0.0, ref = 0.0;
  for (var i = 0; i < n; i++) {
    final d = x[i] - reference[i];
    err += d * d;
    ref += reference[i] * reference[i];
  }
  return 10 * math.log(ref / math.max(err, 1e-30)) / math.ln10;
}

void main() {
  final models = Platform.environment['MODELS_DIR'];
  final refDir = Platform.environment['REAL_REFERENCE'];
  final python = Platform.environment['PYTHON'] ?? 'python3';
  final keep = Platform.environment['REAL_OUT'];
  final skip = models == null || refDir == null ? 'set MODELS_DIR and REAL_REFERENCE to run' : false;

  late Directory tmp;
  setUpAll(() => tmp = Directory.systemTemp.createTempSync('yt_real'));
  tearDownAll(() => tmp.deleteSync(recursive: true));

  Float32List wav(String name) {
    final w = readWavFile('$refDir/$name.wav');
    expect(w.sampleRate, 44100);
    expect(w.channels, 2);
    return w.samples;
  }

  void save(String name, Float32List stereo) {
    if (keep != null) writeWavFile('$keep/$name.wav', stereo, 2, 44100);
  }

  test('UVR-MDX-NET-Voc_FT: Dart demixing matches UVR', () async {
    final mix = wav('mix');
    final model = await PythonOrtModel.start('$models/${vocalModel.fileName}', python: python);
    final watch = Stopwatch()..start();
    final Float32List vocals;
    try {
      vocals = await MdxSeparator(model, MdxConfig.vocFt).separate(mix);
    } finally {
      await model.close();
    }
    final seconds = mix.length / 2 / 44100;
    final agreement = snr(vocals, wav('uvr_vocals'));
    // ignore: avoid_print
    print('MDX: ${seconds.toStringAsFixed(1)} s of audio, ${model.calls} model runs, '
        '${watch.elapsed.inMilliseconds / 1000} s total (${model.inference.inMilliseconds / 1000} s inference); '
        'agreement with UVR ${agreement.toStringAsFixed(1)} dB');
    save('dart_vocals', vocals);
    expect(vocals.length, mix.length);
    expect(agreement, greaterThan(60));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 30)));

  test('6_HP-Karaoke-UVR: the model assembled on the device, Dart inference matches UVR', () async {
    // Build the ONNX model exactly like the app does after downloading.
    final recipe = ModelRecipe.parse(File('assets/models/karaoke_graph.json').readAsStringSync(),
        File('assets/models/karaoke_graph.bin').readAsBytesSync());
    final onnx = '${tmp.path}/${karaokeModel.installedName}';
    expect(recipe.assembleSync('$models/${karaokeModel.fileName}', onnx), recipe.outputSha256);

    final vocals = wav('uvr_vocals');
    final model = await PythonOrtModel.start(onnx, python: python);
    final watch = Stopwatch()..start();
    final Float32List lead, backing;
    try {
      final vr = VrSeparator(model, VrConfig.karaoke6Hp);
      lead = await vr.separate(vocals, stem: VrStem.secondary);
      backing = await vr.separate(vocals, stem: VrStem.primary);
    } finally {
      await model.close();
    }
    final leadAgreement = snr(lead, wav('uvr_lead'));
    final backingAgreement = snr(backing, wav('uvr_backing'));
    // ignore: avoid_print
    print('VR: ${model.calls ~/ 2} model runs per pass, ${watch.elapsed.inMilliseconds / 2000} s per pass '
        '(${model.inference.inMilliseconds / 2000} s inference); agreement with UVR: '
        'lead ${leadAgreement.toStringAsFixed(1)} dB, backing ${backingAgreement.toStringAsFixed(1)} dB');
    save('dart_lead', lead);
    save('dart_backing', backing);
    expect(leadAgreement, greaterThan(40));
    expect(backingAgreement, greaterThan(30));
    // The two stems add up to the input.
    final sum = Float32List(lead.length);
    for (var i = 0; i < sum.length; i++) {
      sum[i] = lead[i] + backing[i];
    }
    expect(snr(sum, Float32List.sublistView(vocals, 0, sum.length)), greaterThan(25));
  }, skip: skip, timeout: const Timeout(Duration(minutes: 30)));
}
