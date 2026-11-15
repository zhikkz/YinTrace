import 'package:wakelock_plus/wakelock_plus.dart';

/// One reason to keep the screen on: a practice, an import, a download, a
/// preview that is playing. The screen stays on while at least one is held,
/// so the end of one (a download finishing in the background) cannot let
/// the screen go dark under another (the practice going on meanwhile).
class ScreenAwake {
  static int _holders = 0;

  /// Switches the system setting. Errors (a platform without the plugin)
  /// are ignored: this is only a convenience. Replaced in tests.
  static Future<void> Function(bool on) platform = _wakelock;

  static Future<void> _wakelock(bool on) => WakelockPlus.toggle(enable: on);

  bool _held = false;
  bool get isHeld => _held;

  void hold() => held = true;
  void release() => held = false;

  /// Holds or releases, whichever [on] says. Doing either twice is the same
  /// as once.
  set held(bool on) {
    if (on == _held) return;
    _held = on;
    _holders += on ? 1 : -1;
    // Only the first holder and the last one change anything.
    if (_holders == (on ? 1 : 0)) _apply(on);
  }

  static Future<void> _apply(bool on) async {
    try {
      await platform(on);
    } catch (_) {}
  }
}
