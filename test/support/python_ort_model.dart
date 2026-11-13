import 'dart:async';
import 'dart:io';
import 'dart:typed_data';

import 'package:yintrace/src/separation/tensor_model.dart';

/// A [TensorModel] that runs a real ONNX model in a Python process
/// (`tools/reference/ort_server.py`), because `flutter test` cannot load the
/// ONNX Runtime plugin. Lets the tests drive the app's Dart separation code
/// with the real UVR models on the host.
class PythonOrtModel implements TensorModel {
  PythonOrtModel._(this._process, this._reader);

  final Process _process;
  final _ByteReader _reader;
  int calls = 0;
  Duration inference = Duration.zero;

  static Future<PythonOrtModel> start(String modelPath, {String python = 'python3'}) async {
    final process = await Process.start(python, ['tools/reference/ort_server.py', modelPath]);
    final errors = StringBuffer();
    process.stderr.transform(const SystemEncoding().decoder).listen(errors.write);
    final model = PythonOrtModel._(process, _ByteReader(process.stdout));
    unawaited(process.exitCode.then((code) {
      if (code != 0) model._reader.fail(StateError('ort_server.py exited with $code:\n$errors'));
    }));
    return model;
  }

  @override
  Future<Float32List> run(Float32List input, List<int> shape) async {
    final watch = Stopwatch()..start();
    final head = Int32List.fromList([shape.length, ...shape]);
    _process.stdin.add(head.buffer.asUint8List());
    _process.stdin.add(input.buffer.asUint8List(input.offsetInBytes, input.lengthInBytes));
    await _process.stdin.flush();
    final rank = (await _reader.read(4)).buffer.asInt32List()[0];
    final dims = (await _reader.read(4 * rank)).buffer.asInt32List();
    final count = dims.fold<int>(1, (a, b) => a * b);
    final data = await _reader.read(4 * count);
    calls++;
    inference += watch.elapsed;
    return data.buffer.asFloat32List();
  }

  @override
  Future<void> close() async {
    await _process.stdin.close();
    await _process.exitCode;
  }
}

/// Reads exact byte counts from a stream.
class _ByteReader {
  _ByteReader(Stream<List<int>> stream) {
    stream.listen((chunk) {
      _chunks.add(chunk is Uint8List ? chunk : Uint8List.fromList(chunk));
      _available += chunk.length;
      _wake();
    }, onDone: () => fail(StateError('model process closed its output')));
  }

  final _chunks = <Uint8List>[];
  int _available = 0;
  int _offset = 0;
  Completer<void>? _waiting;
  Object? _error;

  void fail(Object error) {
    _error ??= error;
    _wake();
  }

  void _wake() {
    final w = _waiting;
    _waiting = null;
    if (w != null && !w.isCompleted) w.complete();
  }

  Future<Uint8List> read(int n) async {
    while (_available < n) {
      if (_error != null) throw _error!;
      _waiting = Completer<void>();
      await _waiting!.future;
    }
    final out = Uint8List(n);
    var filled = 0;
    while (filled < n) {
      final head = _chunks.first;
      final take = (head.length - _offset) < (n - filled) ? head.length - _offset : n - filled;
      out.setRange(filled, filled + take, head, _offset);
      filled += take;
      _offset += take;
      if (_offset == head.length) {
        _chunks.removeAt(0);
        _offset = 0;
      }
    }
    _available -= n;
    return out;
  }
}
