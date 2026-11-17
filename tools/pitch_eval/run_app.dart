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
//                                          as an import measures a vocal;
//   <name>.<cond>.<yin|model>_live.f32     (song time, MIDI) per sample:
//                                          LivePitchTracker / ModelPitchTracker
//                                          at 44.1 kHz in 512-sample blocks,
//                                          as practice measures the singer.
//
// Live, each model run finishes before the next block, as on a phone that
// keeps up with real time.
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

    final up = Float32List.fromList(resample(x, 16000, 44100));
    final t1 = watch.elapsed;
    final LivePitchSource tracker =
        model == null ? LivePitchTracker(sampleRate: 44100) : ModelPitchTracker(sampleRate: 44100, model: SwiftF0(model));
    final points = <double>[];
    void take(List<LivePitch> ps) {
      for (final p in ps) {
        points
          ..add(p.songTime)
          ..add(p.midi);
      }
    }

    for (var i = 0; i < up.length; i += 512) {
      final end = i + 512 < up.length ? i + 512 : up.length;
      take(tracker.addBlock(Float32List.sublistView(up, i, end), i, i, true));
      if (tracker is ModelPitchTracker) await tracker.settle();
      take(tracker.takeReady());
    }
    live += watch.elapsed - t1;
    if (tracker.failure != null) stderr.writeln('$base: the model failed: ${tracker.failure}');
    File('${out.path}/$base.${kind}_live.f32').writeAsBytesSync(Float32List.fromList(points).buffer.asUint8List());
  }
  await model?.close();
  stdout.writeln('$kind: ${seconds.toStringAsFixed(0)} s of audio; import path ${offline.inMilliseconds / 1000} s, '
      'practice path ${live.inMilliseconds / 1000} s');
}
