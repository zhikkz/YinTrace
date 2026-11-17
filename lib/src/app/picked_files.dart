import 'dart:io';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

/// On iOS (and Android) the file picker hands over a copy of the picked
/// file in the app's temporary folder, in a directory of its own:
/// `tmp/flutter_file_picker/<UUID>/<name>` (`cache/file_picker/<n>/<name>`).
/// Nothing removes these copies until the system decides to clear the
/// folder, so every imported song would leave one behind: the app deletes
/// each when it is done with it.
Future<bool> isPickedCopy(String path) async => await _pickedCopy(path) != null;

/// The existing, regular file at `<app temp>/<picker>/<pick>/<name>`.
/// Names alone are not proof of ownership. Resolve the OS-provided temp
/// directory and the file before comparing their directory boundaries.
Future<File?> _pickedCopy(String path) async {
  try {
    final file = File(path);
    if (!file.isAbsolute ||
        path.split('/').any((part) => part == '.' || part == '..')) {
      return null;
    }
    final Directory temporary;
    final String picker;
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        // The picker uses NSTemporaryDirectory (TMPDIR), whereas
        // path_provider returns Library/Caches on iOS.
        temporary = Directory.systemTemp;
        picker = 'flutter_file_picker';
      case TargetPlatform.android:
        temporary = await getTemporaryDirectory(); // Context.getCacheDir()
        picker = 'file_picker';
      default:
        // Desktop pickers can return originals, even from a temp folder.
        return null;
    }
    if (await FileSystemEntity.type(file.path, followLinks: false) !=
            FileSystemEntityType.file ||
        await FileSystemEntity.type(file.parent.path, followLinks: false) !=
            FileSystemEntityType.directory ||
        await FileSystemEntity.type(
              file.parent.parent.path,
              followLinks: false,
            ) !=
            FileSystemEntityType.directory) {
      return null;
    }
    final tempPath = await temporary.resolveSymbolicLinks();
    final resolved = File(await file.resolveSymbolicLinks());
    if (resolved.parent.parent.path != '$tempPath/$picker') return null;
    return resolved;
  } catch (_) {
    // Missing files, unavailable temp paths or links we cannot resolve:
    // leave the source alone unless ownership can be established.
    return null;
  }
}

/// Deletes the picker's copy of a picked file. A path anywhere else is the
/// user's own file (on a desktop the picker returns the file itself) and is
/// left alone.
Future<void> discardPickedCopy(String? path) async {
  if (path == null) return;
  try {
    final file = await _pickedCopy(path);
    if (file == null) return;
    await file.delete();
    // A pick may share its folder with another file still in use. Only
    // remove the folder if it is empty; never recursively delete siblings.
    await file.parent.delete();
  } catch (_) {
    // Already gone, not empty, or still there: the next start sweeps it.
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
