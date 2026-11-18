import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart' as crypto;

/// The pitch model the app bundles: SwiftF0 0.3.0 by Lars Nieradzik (MIT),
/// the official model with its interface adapted for the app's ONNX Runtime
/// plugin by `tools/build_pitch_model.py` (see `assets/models/README.md`).
///
/// It measures the original singer's pitch when a song is imported (the
/// singer's own pitch, live, is measured with YIN). Unlike the two
/// separation models it is small (135 KB) and needed for every import, also
/// of a vocal-only file that needs no download, so it ships with the app.
/// ONNX Runtime loads models from files: [install] copies it out of the
/// app's assets once per version of the model.
abstract final class PitchModel {
  static const asset = 'assets/models/swift_f0.onnx';

  /// What `tools/build_pitch_model.py build` writes (a test checks it).
  static const sha256 = '17aed278f03819b6b4241d7352df25244ce0e918b65049a5e83ec259b25ca014';
  static const bytes = 135466;

  static const inputName = 'audio';
  static const outputName = 'pitch_confidence';

  /// Shown in a song's model info and in diagnostics.
  static const name = 'SwiftF0 0.3.0';

  /// Named after its content: a new model in a later version of the app is
  /// a new file, never mistaken for the old one.
  static String get fileName => 'swift_f0-${sha256.substring(0, 12)}.onnx';

  /// Writes the bundled model into [dir] unless it is there already, and
  /// returns its path. A copy in [dir] that is not the model (checked like
  /// the asset, by its SHA-256) is written again. [load] reads the asset
  /// (`rootBundle.load`). Older versions of the model in [dir] are removed.
  static Future<String> install(Directory dir, Future<ByteData> Function(String asset) load) async {
    final file = File('${dir.path}/$fileName');
    if (file.existsSync() && file.lengthSync() == bytes && _isModel(await file.readAsBytes())) {
      return file.path;
    }
    final data = await load(asset);
    final content = data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes);
    if (!_isModel(content)) {
      throw StateError('the bundled pitch model is not the expected file');
    }
    await dir.create(recursive: true);
    final tmp = File('${file.path}.tmp');
    await tmp.writeAsBytes(content, flush: true);
    await tmp.rename(file.path);
    for (final old in dir.listSync().whereType<File>()) {
      final name = old.uri.pathSegments.last;
      if (name.startsWith('swift_f0-') && name.endsWith('.onnx') && old.path != file.path) {
        try {
          old.deleteSync();
        } catch (_) {}
      }
    }
    return file.path;
  }

  static bool _isModel(List<int> content) =>
      content.length == bytes && '${crypto.sha256.convert(content)}' == sha256;
}
