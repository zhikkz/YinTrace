import 'dart:typed_data';

/// A neural network that maps one float tensor to another.
///
/// The separation pipelines only depend on this interface so that the
/// inference backend (ONNX Runtime today, Core ML / TFLite later) can be
/// swapped per platform, and so that tests can use deterministic fakes.
abstract class TensorModel {
  /// Runs the model on a tensor of the given [shape] (row-major) and returns
  /// the flattened output.
  Future<Float32List> run(Float32List input, List<int> shape);

  Future<void> close();
}

/// Reports progress in [0, 1]. Returning normally continues; throwing
/// (e.g. [SeparationCancelled]) aborts the job.
typedef ProgressCallback = void Function(double fraction);

class SeparationCancelled implements Exception {
  const SeparationCancelled();
  @override
  String toString() => 'Separation cancelled';
}
