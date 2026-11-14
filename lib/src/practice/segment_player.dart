import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

/// Plays short stretches of audio (no microphone): in the pitch editor, the
/// original vocal of one character and a guide tone at its target pitch.
/// Each [play] replaces what was loaded and stops at its end.
class SegmentPlayer extends ChangeNotifier {
  SegmentPlayer({PracticeEngine Function()? engineFactory, this.configureSession = true})
    : _factory = engineFactory ?? (() => PracticeEngine.create(mode: EngineMode.playback));

  final PracticeEngine Function() _factory;

  /// Sets the audio session up for playback first (off in tests).
  final bool configureSession;

  PracticeEngine? _engine;
  bool _deviceOn = false;
  Timer? _poll;

  static const vocalSlot = 0;
  static const toneSlot = 1;

  PracticeEngine? get engine => _engine;
  bool get playing => _engine?.isPlaying ?? false;

  /// Plays [vocal] and [tone] (mono, 44.1 kHz, both starting at the same
  /// moment) with the given gains, from their start to their end.
  void play({Float32List? vocal, Float32List? tone, double vocalGain = 1, double toneGain = 1}) {
    final e = _engine ??= _factory();
    if (configureSession) NativeAudio.configureSession(record: false);
    e.pause();
    for (final (slot, pcm) in [(vocalSlot, vocal), (toneSlot, tone)]) {
      if (pcm != null && pcm.isNotEmpty) {
        e.loadTrackPcm(slot, pcm, 1);
      } else {
        e.unloadTrack(slot);
      }
    }
    e.setTrackGain(vocalSlot, vocalGain);
    e.setTrackGain(toneSlot, toneGain);
    e.seekFrame(0);
    // Every time: after unplugged headphones or a call the engine is
    // silenced until it is started again (a no-op while it runs).
    e.takeAudioEvents();
    e.start();
    _deviceOn = true;
    e.play();
    _poll ??= Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!playing) {
        _poll?.cancel();
        _poll = null;
      }
      notifyListeners();
    });
    notifyListeners();
  }

  void stop() {
    _engine?.pause();
    notifyListeners();
  }

  /// Stops the audio device too (the app left the foreground).
  void suspend() {
    final e = _engine;
    if (e == null) return;
    e.pause();
    if (_deviceOn) {
      try {
        e.stop();
      } catch (_) {}
      _deviceOn = false;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _poll?.cancel();
    final e = _engine;
    _engine = null;
    if (e != null) {
      try {
        e.stop();
      } catch (_) {}
      e.dispose();
    }
    super.dispose();
  }
}
