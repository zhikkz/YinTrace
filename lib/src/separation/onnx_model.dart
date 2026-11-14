import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'tensor_model.dart';

/// [TensorModel] backed by ONNX Runtime (via the flutter_onnxruntime plugin,
/// which runs inference on a native background queue).
class OnnxTensorModel implements TensorModel {
  OnnxTensorModel._(this._session, this.inputName, this.outputName);

  final OrtSession _session;
  final String inputName;
  final String outputName;

  /// Loads a model on the CPU execution provider, without ONNX Runtime's
  /// memory arena (it would keep the peak allocation for the session's
  /// lifetime).
  static Future<OnnxTensorModel> load(
    String path, {
    String? inputName,
    String? outputName,
    int? threads,
  }) async {
    final ort = OnnxRuntime();
    final providers = <OrtProvider>[OrtProvider.CPU];
    final session = await ort.createSession(
      path,
      options: OrtSessionOptions(providers: providers, intraOpNumThreads: threads ?? 4, useArena: false),
    );
    final inName = inputName != null && session.inputNames.contains(inputName)
        ? inputName
        : session.inputNames.first;
    final outName = outputName != null && session.outputNames.contains(outputName)
        ? outputName
        : session.outputNames.first;
    return OnnxTensorModel._(session, inName, outName);
  }

  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    final value = await OrtValue.fromList(input, shape);
    try {
      final outputs = await _session.run({inputName: value});
      final out = outputs[outputName] ?? outputs.values.first;
      try {
        final data = await out.asFlattenedList();
        if (data is Float32List) return data;
        return Float32List.fromList(data.cast<num>().map((e) => e.toDouble()).toList());
      } finally {
        for (final o in outputs.values) {
          await o.dispose();
        }
      }
    } finally {
      await value.dispose();
    }
  }

  @override
  Future<void> close() => _session.close();
}
