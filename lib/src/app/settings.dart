import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

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

  /// Live microphone monitoring level. Enabling it belongs to each practice
  /// session, so a new session never opens the live microphone to output.
  double monitorVolume = 0.5;

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
    final monitor = (j['monitorVolume'] as num?)?.toDouble();
    if (monitor != null && monitor.isFinite) monitorVolume = monitor.clamp(0.0, 1.0);
    guideVocalOn = j['guideVocalOn'] as bool? ?? guideVocalOn;
    headphoneTipSeen = j['headphoneTipSeen'] as bool? ?? headphoneTipSeen;
    measurementMode = j['measurementMode'] as bool? ?? measurementMode;
    practiceWindowSeconds = (j['practiceWindowSeconds'] as num?)?.toDouble() ?? practiceWindowSeconds;
  }

  Map<String, dynamic> toJson() => {
    'latencyOffsetMs': latencyOffsetMs,
    'toleranceCents': toleranceCents,
    'octaveTolerant': octaveTolerant,
    'micGateDb': micGateDb,
    'accompanimentVolume': accompanimentVolume,
    'guideVocalVolume': guideVocalVolume,
    'monitorVolume': monitorVolume,
    'guideVocalOn': guideVocalOn,
    'headphoneTipSeen': headphoneTipSeen,
    'measurementMode': measurementMode,
    'practiceWindowSeconds': practiceWindowSeconds,
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
