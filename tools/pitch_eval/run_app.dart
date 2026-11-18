// Runs the app's own pitch code on the clips render.py wrote:
//
//   dart --packages=.dart_tool/package_config.json tools/pitch_eval/run_app.dart \
//       <rendered dir> <tracks dir> yin|model [conditions...]
//
// Run from the repository root after `flutter pub get`. `model` runs the
// bundled SwiftF0 model in ONNX Runtime for Python, as the tests do
// (PYTHON selects the interpreter). For each clip and condition it writes
//
//   <name>.<cond>.<yin|model>_offline.f32  hop (s), then MIDI per frame:
//                                          analyzePitch / analyzePitchWithModel,
//                                          as an import measures the original
//                                          singer's (separated) vocal;
//   <name>.<cond>.yin_live.f32             with `yin` only: (song time, MIDI)
//                                          per sample from LivePitchTracker at
//                                          44.1 kHz in 512-sample blocks, as
//                                          practice measures the singer.
import 'dart:io';
import 'dart:typed_data';

import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/dsp/resampler.dart';
import 'package:yintrace/src/dsp/swift_f0.dart';
import 'package:yintrace/src/models/pitch_model.dart';
import 'package:yintrace/src/practice/live_pitch.dart';

import '../../test/support/python_ort_model.dart';

Future<void> main(List<String> args) async {
  final dir = Directory(args[0]);
  final out = Directory(args[1])..createSync(recursive: true);
  final useModel = args[2] == 'model';
  final conds = args.length > 3 ? args.sublist(3) : null;
  final model = useModel
      ? await PythonOrtModel.start(PitchModel.asset, python: Platform.environment['PYTHON'] ?? 'python3')
      : null;
  final kind = useModel ? 'model' : 'yin';
  final files = dir.listSync().whereType<File>().where((f) => f.path.endsWith('.f32')).toList()
    ..sort((a, b) => a.path.compareTo(b.path));
  final watch = Stopwatch()..start();
  var offline = Duration.zero, live = Duration.zero, seconds = 0.0;
  for (final f in files) {
    final base = f.uri.pathSegments.last.replaceAll('.f32', '');
    if (conds != null && !conds.contains(base.split('.').last)) continue;
    final bytes = f.readAsBytesSync();
    final x = Float32List.view(bytes.buffer, bytes.offsetInBytes, bytes.lengthInBytes ~/ 4);
    seconds += x.length / 16000;

    final t0 = watch.elapsed;
    final track = model == null ? analyzePitch(x, 16000) : await analyzePitchWithModel(x, 16000, SwiftF0(model));
    offline += watch.elapsed - t0;
    final grid = Float32List(track.length + 1)..[0] = track.hopSeconds;
    grid.setRange(1, grid.length, track.midi);
    File('${out.path}/$base.${kind}_offline.f32').writeAsBytesSync(grid.buffer.asUint8List());
    if (model != null) continue;

    final up = Float32List.fromList(resample(x, 16000, 44100));
    final t1 = watch.elapsed;
    final tracker = LivePitchTracker(sampleRate: 44100);
    final points = <double>[];
    for (var i = 0; i < up.length; i += 512) {
      final end = i + 512 < up.length ? i + 512 : up.length;
      for (final p in tracker.addBlock(Float32List.sublistView(up, i, end), i, i, true)) {
        points
          ..add(p.songTime)
          ..add(p.midi);
      }
    }
    live += watch.elapsed - t1;
    File('${out.path}/$base.yin_live.f32').writeAsBytesSync(Float32List.fromList(points).buffer.asUint8List());
  }
  await model?.close();
  stdout.writeln('$kind: ${seconds.toStringAsFixed(0)} s of audio; import path ${offline.inMilliseconds / 1000} s'
      '${model == null ? ', practice path ${live.inMilliseconds / 1000} s' : ''}');
}
