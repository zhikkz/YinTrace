import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart' show PracticeEngine;

import 'atomic_file.dart';

/// User preferences, persisted as JSON.
class AppSettings extends ChangeNotifier {
  AppSettings(this._file);

  final File? _file;

  /// Writes the file: one write at a time, each replacing the file in one
  /// step, so that changes in quick succession (a slider) cannot leave it
  /// half written.
  late final LatestStateWriter? _writer = switch (_file) {
    final file? => LatestStateWriter(file, () => jsonEncode(toJson())),
    null => null,
  };

  /// Extra latency compensation in milliseconds, added to the value the OS
  /// reports (positive = your voice is shown earlier).
  int latencyOffsetMs = 0;

  /// Tolerance counted as "on pitch" (cents).
  int toleranceCents = 50;
  bool octaveTolerant = true;

  /// Microphone gate (dBFS); quieter input counts as silence.
  double micGateDb = -50;
  double accompanimentVolume = 0.9;
  double guideVocalVolume = 0.35;

  /// Live microphone monitoring level: the slider position, 0..1, heard as
  /// [monitorGain]. Enabling it belongs to each practice session, so a new
  /// session never opens the live microphone to output.
  double monitorLevel = 0.5;

  /// The engine's monitor gain for [monitorLevel]: a square taper up to
  /// [PracticeEngine.maxMonitorGain], exactly 0 at 0. The engine compresses
  /// the voice before this gain (a typical -24 dBFS phone-mic voice comes out
  /// at about -28.5 dBFS), so 50% (+12 dB) puts it at about -16.5 dBFS, about
  /// level with an accompaniment at about -14 dBFS. 25% is unity (the old
  /// maximum), 75% +19 dB and 100% +24 dB, for quiet singers and loud songs;
  /// the engine limits the peaks. The square keeps the low end fine-grained.
  double get monitorGain {
    final v = monitorLevel.isFinite ? monitorLevel.clamp(0.0, 1.0) : 0.0;
    return PracticeEngine.maxMonitorGain * v * v;
  }

  /// The original singer plays quietly along while practising (导唱), at
  /// [guideVocalVolume]. Off: the accompaniment alone, the volume kept for
  /// when it is turned on again.
  bool guideVocalOn = true;

  /// The practice page told the singer once to wear headphones.
  bool headphoneTipSeen = false;

  /// Disables iOS voice processing / AGC for more stable pitch readings.
  bool measurementMode = false;

  /// Seconds of the pitch graph visible during practice.
  double practiceWindowSeconds = 6;

  /// Test builds: imports measure the original singer's pitch with YIN
  /// instead of the pitch model, to compare the two. (The singer's own
  /// pitch is measured with YIN either way.)
  bool yinPitch = false;

  static Future<AppSettings> load(File file) async {
    final s = AppSettings(file);
    if (file.existsSync()) {
      try {
        s._apply(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } catch (_) {
        // Corrupt settings: keep defaults.
      }
    }
    return s;
  }

  void _apply(Map<String, dynamic> j) {
    latencyOffsetMs = (j['latencyOffsetMs'] as num?)?.toInt() ?? latencyOffsetMs;
    toleranceCents = (j['toleranceCents'] as num?)?.toInt() ?? toleranceCents;
    octaveTolerant = j['octaveTolerant'] as bool? ?? octaveTolerant;
    micGateDb = (j['micGateDb'] as num?)?.toDouble() ?? micGateDb;
    accompanimentVolume = (j['accompanimentVolume'] as num?)?.toDouble() ?? accompanimentVolume;
    guideVocalVolume = (j['guideVocalVolume'] as num?)?.toDouble() ?? guideVocalVolume;
    // The old 'monitorVolume' (a plain 0..1 gain) is ignored: a slider pushed
    // to the top to hear that quiet monitor would now mean +24 dB.
    final monitor = (j['monitorLevel'] as num?)?.toDouble();
    if (monitor != null && monitor.isFinite) monitorLevel = monitor.clamp(0.0, 1.0);
    guideVocalOn = j['guideVocalOn'] as bool? ?? guideVocalOn;
    headphoneTipSeen = j['headphoneTipSeen'] as bool? ?? headphoneTipSeen;
    measurementMode = j['measurementMode'] as bool? ?? measurementMode;
    practiceWindowSeconds = (j['practiceWindowSeconds'] as num?)?.toDouble() ?? practiceWindowSeconds;
    yinPitch = j['yinPitch'] as bool? ?? yinPitch;
  }

  Map<String, dynamic> toJson() => {
    'latencyOffsetMs': latencyOffsetMs,
    'toleranceCents': toleranceCents,
    'octaveTolerant': octaveTolerant,
    'micGateDb': micGateDb,
    'accompanimentVolume': accompanimentVolume,
    'guideVocalVolume': guideVocalVolume,
    'monitorLevel': monitorLevel,
    'guideVocalOn': guideVocalOn,
    'headphoneTipSeen': headphoneTipSeen,
    'measurementMode': measurementMode,
    'practiceWindowSeconds': practiceWindowSeconds,
    'yinPitch': yinPitch,
  };

  /// Applies [change], notifies listeners and saves.
  Future<void> update(void Function(AppSettings s) change) {
    this.change(change);
    return save();
  }

  /// Applies [change] and notifies listeners without saving yet: for a value
  /// that is still being dragged. Call [save] when it has settled.
  void change(void Function(AppSettings s) change) {
    change(this);
    notifyListeners();
  }

  /// Completes when the settings as they are now are in the file.
  Future<void> save() => _writer?.save() ?? Future.value();
}
