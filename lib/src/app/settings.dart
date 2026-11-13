import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

/// User preferences, persisted as JSON.
class AppSettings extends ChangeNotifier {
  AppSettings(this._file);

  final File? _file;

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

  /// Disables iOS voice processing / AGC for more stable pitch readings.
  bool measurementMode = false;

  /// Try the Core ML execution provider for separation (Apple devices).
  bool useCoreML = false;

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
    measurementMode = j['measurementMode'] as bool? ?? measurementMode;
    useCoreML = j['useCoreML'] as bool? ?? useCoreML;
    practiceWindowSeconds = (j['practiceWindowSeconds'] as num?)?.toDouble() ?? practiceWindowSeconds;
  }

  Map<String, dynamic> toJson() => {
        'latencyOffsetMs': latencyOffsetMs,
        'toleranceCents': toleranceCents,
        'octaveTolerant': octaveTolerant,
        'micGateDb': micGateDb,
        'accompanimentVolume': accompanimentVolume,
        'guideVocalVolume': guideVocalVolume,
        'measurementMode': measurementMode,
        'useCoreML': useCoreML,
        'practiceWindowSeconds': practiceWindowSeconds,
      };

  /// Applies [change], notifies listeners and saves.
  Future<void> update(void Function(AppSettings s) change) async {
    change(this);
    notifyListeners();
    final f = _file;
    if (f != null) {
      await f.parent.create(recursive: true);
      await f.writeAsString(jsonEncode(toJson()));
    }
  }
}
