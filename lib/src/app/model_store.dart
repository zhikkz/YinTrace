import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

/// Kinds of separation models the app needs.
enum ModelKind {
  mdx('人声分离', 'UVR-MDX-NET-Voc_FT'),
  vr('去和声', '6_HP-Karaoke-UVR');

  const ModelKind(this.label, this.recommended);
  final String label;
  final String recommended;
}

class ModelFile {
  ModelFile(this.path, this.kind, {this.hasSidecar = false});
  final String path;
  final ModelKind kind;
  final bool hasSidecar;
  String get name => path.split('/').last;
  int get sizeBytes => File(path).lengthSync();
}

/// Finds and installs the ONNX separation models.
///
/// Models live in `<Documents>/models` (visible in the iOS Files app, so
/// they can be copied there from a computer) and may also be bundled as
/// Flutter assets under `assets/models/`.
class ModelStore {
  ModelStore(this.dir);

  final Directory dir;

  List<ModelFile> list() {
    if (!dir.existsSync()) return [];
    final out = <ModelFile>[];
    for (final f in dir.listSync().whereType<File>()) {
      if (!f.path.toLowerCase().endsWith('.onnx')) continue;
      final base = f.path.substring(0, f.path.length - 5);
      final side = File('$base.json');
      ModelKind? kind;
      if (side.existsSync()) {
        try {
          final j = jsonDecode(side.readAsStringSync()) as Map<String, dynamic>;
          kind = j['type'] == 'vr' ? ModelKind.vr : j['type'] == 'mdx' ? ModelKind.mdx : null;
        } catch (_) {}
      }
      kind ??= _guessKind(f.path.split('/').last);
      if (kind != null) out.add(ModelFile(f.path, kind, hasSidecar: side.existsSync()));
    }
    out.sort((a, b) => a.name.compareTo(b.name));
    return out;
  }

  static ModelKind? _guessKind(String name) {
    final n = name.toLowerCase();
    if (n.contains('karaoke') || n.contains('_hp') || n.contains('hp-') || n.contains('vr')) {
      return ModelKind.vr;
    }
    if (n.contains('mdx') || n.contains('voc')) return ModelKind.mdx;
    return null;
  }

  /// The model to use for [kind]: the recommended one if present.
  String? pathFor(ModelKind kind) {
    final candidates = list().where((m) => m.kind == kind).toList();
    if (candidates.isEmpty) return null;
    final key = kind.recommended.toLowerCase();
    return (candidates.firstWhere((m) => m.name.toLowerCase().contains(key),
            orElse: () => candidates.first))
        .path;
  }

  /// Copies a model (and its sidecar `.json`, if next to it) into the store.
  Future<String> importFile(String source) async {
    await dir.create(recursive: true);
    final name = source.split('/').last;
    final dest = '${dir.path}/$name';
    await File(source).copy(dest);
    if (name.toLowerCase().endsWith('.onnx')) {
      final side = File('${source.substring(0, source.length - 5)}.json');
      if (side.existsSync()) {
        await side.copy('${dest.substring(0, dest.length - 5)}.json');
      }
    }
    return dest;
  }

  Future<void> delete(ModelFile m) async {
    await File(m.path).delete();
    final side = File('${m.path.substring(0, m.path.length - 5)}.json');
    if (side.existsSync()) await side.delete();
  }

  /// Copies models bundled under `assets/models/` on first launch.
  Future<int> installBundled(AssetBundle bundle) async {
    var copied = 0;
    try {
      final manifest = await AssetManifest.loadFromAssetBundle(bundle);
      for (final key in manifest.listAssets()) {
        if (!key.startsWith('assets/models/')) continue;
        final lower = key.toLowerCase();
        if (!lower.endsWith('.onnx') && !lower.endsWith('.json')) continue;
        final dest = File('${dir.path}/${key.split('/').last}');
        if (dest.existsSync()) continue;
        await dir.create(recursive: true);
        final data = await bundle.load(key);
        await dest.writeAsBytes(data.buffer.asUint8List(data.offsetInBytes, data.lengthInBytes), flush: true);
        copied++;
      }
    } catch (_) {
      // No bundled models.
    }
    return copied;
  }
}
