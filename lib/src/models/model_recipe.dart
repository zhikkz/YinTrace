import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';

/// A copy recipe that turns the official `6_HP-Karaoke-UVR.pth` into an ONNX
/// model (see `tools/build_karaoke_graph.py`).
///
/// A `.pth` file is a zip archive holding every weight tensor as raw
/// little-endian floats. The ONNX file is the network graph ([graph], bundled
/// with the app, ~130 KB) with those same tensors in between, so it can be
/// assembled by copying byte ranges - no PyTorch needed on the device.
class ModelRecipe {
  ModelRecipe({
    required this.graph,
    required this.segments,
    required this.sourceBytes,
    required this.sourceSha256,
    required this.outputBytes,
    required this.outputSha256,
  });

  /// Everything in the ONNX file that is not weight data.
  final Uint8List graph;

  /// `[literal bytes from graph, offset in the source, bytes from the source]`.
  final List<List<int>> segments;
  final int sourceBytes;
  final String sourceSha256;
  final int outputBytes;
  final String outputSha256;

  factory ModelRecipe.parse(String json, Uint8List graph) {
    final j = jsonDecode(json) as Map<String, dynamic>;
    if (j['format'] != 'yintrace-model-recipe' || j['version'] != 1) {
      throw const FormatException('unknown model recipe');
    }
    final g = j['graph'] as Map<String, dynamic>;
    if (g['bytes'] != graph.length || sha256.convert(graph).toString() != g['sha256']) {
      throw const FormatException('model graph does not match its recipe');
    }
    final source = j['source'] as Map<String, dynamic>;
    final output = j['output'] as Map<String, dynamic>;
    return ModelRecipe(
      graph: graph,
      segments: [
        for (final s in j['segments'] as List) [for (final v in s as List) (v as num).toInt()]
      ],
      sourceBytes: (source['bytes'] as num).toInt(),
      sourceSha256: source['sha256'] as String,
      outputBytes: (output['bytes'] as num).toInt(),
      outputSha256: output['sha256'] as String,
    );
  }

  /// Writes the ONNX model assembled from [source] to [output] and returns
  /// the SHA-256 of what was written. Synchronous: run it in an isolate.
  String assembleSync(String source, String output) {
    final src = File(source).openSync();
    final out = File(output).openSync(mode: FileMode.write);
    final hash = _Sha256Sink();
    try {
      final buffer = Uint8List(1 << 20);
      var pos = 0;
      for (final s in segments) {
        final literal = s[0], offset = s[1];
        var remaining = s[2];
        if (literal > 0) {
          final part = Uint8List.sublistView(graph, pos, pos + literal);
          out.writeFromSync(part);
          hash.add(part);
          pos += literal;
        }
        if (remaining > 0) src.setPositionSync(offset);
        while (remaining > 0) {
          final want = remaining < buffer.length ? remaining : buffer.length;
          final got = src.readIntoSync(buffer, 0, want);
          if (got <= 0) throw const FileSystemException('model file is truncated');
          out.writeFromSync(buffer, 0, got);
          hash.add(Uint8List.sublistView(buffer, 0, got));
          remaining -= got;
        }
      }
      if (pos != graph.length) throw const FormatException('recipe does not use the whole graph');
    } finally {
      src.closeSync();
      out.closeSync();
    }
    return hash.close();
  }
}

/// SHA-256 of a file, hex encoded. Synchronous: run it in an isolate.
String sha256OfFileSync(String path) {
  final f = File(path).openSync();
  final hash = _Sha256Sink();
  try {
    final buffer = Uint8List(1 << 20);
    while (true) {
      final got = f.readIntoSync(buffer);
      if (got <= 0) break;
      hash.add(Uint8List.sublistView(buffer, 0, got));
    }
  } finally {
    f.closeSync();
  }
  return hash.close();
}

class _Sha256Sink {
  _Sha256Sink() {
    _input = sha256.startChunkedConversion(_out);
  }

  final _out = _DigestSink();
  late final ByteConversionSink _input;

  void add(Uint8List data) => _input.add(data);

  String close() {
    _input.close();
    return _out.value.toString();
  }
}

class _DigestSink implements Sink<Digest> {
  late Digest value;

  @override
  void add(Digest data) => value = data;

  @override
  void close() {}
}
