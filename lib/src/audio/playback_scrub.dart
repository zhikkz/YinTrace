import 'package:yintrace_audio/yintrace_audio.dart';

/// Holds the audio clock while a seek gesture previews a new position.
class PlaybackScrub {
  bool _active = false;
  bool _resumePlayback = false;
  double? _position;

  bool get active => _active;
  double? get position => _position;

  bool isPlaying(PracticeEngine? engine) => _active ? _resumePlayback : (engine?.isPlaying ?? false);

  bool begin(PracticeEngine? engine) {
    if (engine == null || _active) return false;
    _resumePlayback = engine.isPlaying;
    engine.pause();
    _active = true;
    return true;
  }

  void update(double seconds) {
    if (_active) _position = seconds;
  }

  void stayPaused() => _resumePlayback = false;

  void end(PracticeEngine? engine, void Function(double) seek) {
    final target = _position;
    final resume = _resumePlayback;
    _clear();
    if (target != null) seek(target);
    if (resume) engine?.play();
  }

  void cancel(PracticeEngine? engine, {bool resume = true}) {
    final shouldPlay = resume && _resumePlayback;
    _clear();
    if (shouldPlay) engine?.play();
  }

  void _clear() {
    _active = false;
    _resumePlayback = false;
    _position = null;
  }
}
