import 'package:wakelock_plus/wakelock_plus.dart';

/// Keeps the screen on during long jobs / practice. Errors (e.g. on a
/// platform without the plugin) are ignored: this is only a convenience.
Future<void> keepScreenOn(bool on) async {
  try {
    await WakelockPlus.toggle(enable: on);
  } catch (_) {}
}
