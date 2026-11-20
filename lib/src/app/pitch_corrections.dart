import 'dart:async';

import 'package:flutter/foundation.dart';

import 'pitch_correction_session.dart';

/// Keeps corrections alive while an editor is open or still has work to save.
/// A reopened editor sees the same reference and pending edits.
class PitchCorrections extends ChangeNotifier {
  final _active = <String, _CorrectionEntry>{};
  final _savedRevisions = <String, int>{};
  final _backgroundFailures = <String, String>{};
  bool _notificationQueued = false;

  bool busyFor(String songId) => _active[songId]?.session.busy ?? false;
  bool get usesModel => _active.values.any((entry) => entry.session.usingModel);
  int savedRevisionFor(String songId) => _savedRevisions[songId] ?? 0;
  String? takeBackgroundFailure(String songId) => _backgroundFailures.remove(songId);

  PitchCorrectionSession attach(String songId, PitchCorrectionSession Function() create) {
    final entry = _active.putIfAbsent(songId, () {
      final session = create();
      final entry = _CorrectionEntry(session);
      entry.listener = () => _changed(entry);
      session.addListener(entry.listener);
      return entry;
    });
    entry.editors++;
    return entry.session;
  }

  void detach(PitchCorrectionSession session) {
    final entry = _active[session.songId];
    if (entry == null || !identical(entry.session, session)) return;
    entry.editors--;
    _removeWhenIdle(entry);
  }

  void _changed(_CorrectionEntry entry) {
    final session = entry.session;
    final id = session.songId;
    if (entry.savedRevision != session.savedRevision) {
      _savedRevisions[id] = savedRevisionFor(id) + 1;
      entry.savedRevision = session.savedRevision;
    }
    if (entry.failureRevision != session.failureRevision) {
      if (session.lastFailure case final failure? when entry.editors == 0) {
        _backgroundFailures[id] = failure;
      }
      entry.failureRevision = session.failureRevision;
    }
    _removeWhenIdle(entry);
    if (!_notificationQueued) {
      _notificationQueued = true;
      scheduleMicrotask(() {
        _notificationQueued = false;
        notifyListeners();
      });
    }
  }

  void _removeWhenIdle(_CorrectionEntry entry) {
    final session = entry.session;
    if (entry.editors != 0 || session.busy) return;
    // A session can reach idle inside its own notification.
    scheduleMicrotask(() {
      if (!identical(_active[session.songId], entry) || entry.editors != 0 || session.busy) return;
      _active.remove(session.songId);
      session.removeListener(entry.listener);
      session.dispose();
    });
  }
}

class _CorrectionEntry {
  _CorrectionEntry(this.session);

  final PitchCorrectionSession session;
  late final VoidCallback listener;
  int editors = 0;
  int savedRevision = 0;
  int failureRevision = 0;
}
