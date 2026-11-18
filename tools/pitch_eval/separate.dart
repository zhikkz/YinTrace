// Separates the vocal from the mixes render.py wrote, the way an import
// does, so that the pitch can be measured on what the app really measures:
//
//   dart --packages=.dart_tool/package_config.json tools/pitch_eval/separate.dart \
//       <rendered dir> <UVR-MDX-NET-Voc_FT.onnx> [mix condition] [out condition]
//
// Run from the repository root. Defaults: mix+0 (the voice and the
// accompaniment at the same energy, MIR-1K's usual mix) into sep+0. The
// official model file gets the app's dynamic-axis recipe, then the app's
// MdxSeparator runs it (in ONNX Runtime for Python, as the tests do; PYTHON
// selects the interpreter) on the mix at 44.1 kHz stereo. The vocal is
// mixed to mono as ImportPipeline does, brought back to 16 kHz and written
// as a new condition next to the others; meta.json lists it.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:yintrace/src/dsp/resampler.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/models/model_recipe.dart';
import 'package:yintrace/src/separation/mdx_separator.dart';
import 'package:yintrace/src/separation/model_config.dart';

import '../../test/support/python_ort_model.dart';

Future<void> main(List<String> args) async {
  final dir = args[0];
  final official = args[1];
  final from = args.length > 2 ? args[2] : 'mix+0';
  final to = args.length > 3 ? args[3] : 'sep+0';
  final metaFile = File('$dir/meta.json');
  final meta = jsonDecode(metaFile.readAsStringSync()) as Map<String, dynamic>;

  final recipe = ModelRecipe.parse(
    File('assets/models/mdx_graph.json').readAsStringSync(),
    File('assets/models/mdx_graph.bin').readAsBytesSync(),
  );
  final tmp = Directory.systemTemp.createTempSync('pitch_eval_mdx');
  final onnx = '${tmp.path}/${vocalModel.installedName}';
  if (recipe.assembleSync(official, onnx) != recipe.outputSha256) {
    throw StateError('$official is not the official ${vocalModel.fileName}');
  }
  final model = await PythonOrtModel.start(onnx, python: Platform.environment['PYTHON'] ?? 'python3');
  final watch = Stopwatch()..start();
  var seconds = 0.0;
  try {
    for (final clip in (meta['clips'] as List).cast<Map<String, dynamic>>()) {
      final name = clip['name'] as String;
      final bytes = File('$dir/$name.$from.f32').readAsBytesSync();
      final x = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
      seconds += x.length / 16000;
      final up = resample(x, 16000, 44100);
      final stereo = Float32List(up.length * 2);
      for (var i = 0; i < up.length; i++) {
        stereo[2 * i] = up[i];
        stereo[2 * i + 1] = up[i];
      }
      final vocals = await MdxSeparator(model, MdxConfig.vocFt).separate(stereo);
      final mono = Float32List(vocals.length ~/ 2);
      for (var i = 0; i < mono.length; i++) {
        mono[i] = 0.5 * (vocals[2 * i] + vocals[2 * i + 1]);
      }
      final down = Float32List.fromList(resample(mono, 44100, 16000));
      File('$dir/$name.$to.f32').writeAsBytesSync(down.buffer.asUint8List());
    }
  } finally {
    await model.close();
    tmp.deleteSync(recursive: true);
  }
  final conditions = (meta['conditions'] as List).cast<String>();
  if (!conditions.contains(to)) {
    meta['conditions'] = [...conditions, to];
    metaFile.writeAsStringSync(jsonEncode(meta));
  }
  stdout.writeln('separated ${seconds.toStringAsFixed(0)} s of $from into $to in '
      '${(watch.elapsedMilliseconds / 1000).toStringAsFixed(0)} s');
}
