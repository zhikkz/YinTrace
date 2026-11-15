import 'dart:io';

import 'package:file_picker/file_picker.dart';

/// On iOS (and Android) the file picker hands over a copy of the picked
/// file in the app's temporary folder, in a directory of its own:
/// `tmp/flutter_file_picker/<UUID>/<name>` (`cache/file_picker/<n>/<name>`).
/// Nothing removes these copies until the system decides to clear the
/// folder, so every imported song would leave one behind: the app deletes
/// each when it is done with it.
bool isPickedCopy(String path) {
  final parts = path.split(RegExp(r'[/\\]'));
  if (parts.length < 3) return false;
  final root = parts[parts.length - 3];
  return root == 'flutter_file_picker' || root == 'file_picker';
}

/// Deletes the picker's copy of a picked file. A path anywhere else is the
/// user's own file (on a desktop the picker returns the file itself) and is
/// left alone.
Future<void> discardPickedCopy(String? path) async {
  if (path == null || !isPickedCopy(path)) return;
  try {
    final dir = File(path).parent;
    if (await dir.exists()) await dir.delete(recursive: true);
  } catch (_) {
    // Still there: the sweep at the next start gets it.
  }
}

/// Removes every copy the picker left behind (by an earlier version, or an
/// import that was cut off). For when nothing picked is in use: at start.
Future<void> sweepPickedCopies() async {
  if (!Platform.isIOS) return;
  try {
    await FilePicker.clearTemporaryFiles();
  } catch (_) {}
}
