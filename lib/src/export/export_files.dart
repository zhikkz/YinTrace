import 'dart:io';

import 'package:path_provider/path_provider.dart';

/// Where the export page and the song share sheet write. On iOS the
/// documents folder, which the Files app shows. On Android nothing outside
/// the app sees that folder, so exports go to a cache folder instead: the
/// share sheet and the "save as" dialog give the singer their copy, and the
/// app deletes its own when the page closes.
Future<Directory> exportDirectory() async => Platform.isAndroid
    ? Directory('${(await getTemporaryDirectory()).path}/exports')
    : getApplicationDocumentsDirectory();

/// At start, on Android: deletes the exports an earlier run left behind (it
/// was closed before its page), and the ones 1.0.0 kept in the documents
/// folder, where nobody could get to them.
Future<void> sweepAndroidExports() async {
  if (!Platform.isAndroid) return;
  try {
    await sweepExports(exports: await exportDirectory(), documents: await getApplicationDocumentsDirectory());
  } catch (_) {
    // Best effort: the next start tries again.
  }
}

/// Empties [exports], and deletes the finished tracks and song files
/// directly in [documents]. Folders there (the Flutter engine's assets) and
/// other files stay.
Future<void> sweepExports({required Directory exports, required Directory documents}) async {
  if (await exports.exists()) {
    await for (final entry in exports.list(followLinks: false)) {
      await _delete(entry);
    }
  }
  if (await documents.exists()) {
    await for (final entry in documents.list(followLinks: false)) {
      if (entry is File && _exportSuffixes.any(entry.path.endsWith)) await _delete(entry);
    }
  }
}

/// What the export page (`.m4a`, `.wav`) and the song share sheet
/// (`.yintrace`, and its partial `.yintrace.tmp`) write.
const _exportSuffixes = ['.m4a', '.wav', '.yintrace', '.yintrace.tmp'];

Future<void> _delete(FileSystemEntity entry) async {
  try {
    await entry.delete(recursive: true);
  } catch (_) {}
}
