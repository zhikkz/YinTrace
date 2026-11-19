import 'dart:async';

import '../separation/tensor_model.dart';

/// Keeps one import model resident at a time. Jobs waiting for the current
/// model can use it before the next stage swaps in another one.
class ImportModelPool {
  final _waiting = <_ModelUse>[];
  final _active = <_ModelUse>{};
  Object? _key;
  _ResidentModel? _resident;
  Future<void>? _switching;

  Future<T> use<M extends Object, T>(
    Object key, {
    required Future<M> Function() load,
    required Future<void> Function(M) close,
    required Future<T> Function(M) run,
    bool Function()? isCancelled,
    bool Function()? canOverlap,
  }) {
    final result = Completer<T>();
    _waiting.add(
      _ModelUse(key, isCancelled, canOverlap, () async {
        try {
          final model = _resident ??= _ResidentModel(
            Future.sync(load),
            (model) => close(model as M),
          );
          final M loaded;
          try {
            loaded = await model.loading as M;
          } catch (_) {
            if (identical(_resident, model)) _resident = null;
            rethrow;
          }
          if (isCancelled?.call() ?? false) throw const SeparationCancelled();
          result.complete(await run(loaded));
        } catch (error, stack) {
          result.completeError(error, stack);
        }
      }, () => result.completeError(const SeparationCancelled())),
    );
    _dispatch();
    return result.future;
  }

  /// Canceled jobs waiting for another song's stage can finish immediately.
  void cancelPending() {
    _waiting.removeWhere((task) {
      if (!(task.isCancelled?.call() ?? false)) return false;
      task.cancel();
      return true;
    });
  }

  void _dispatch() {
    if (_switching != null || _waiting.isEmpty) return;
    cancelPending();
    if (_waiting.isEmpty) return;

    final match = _waiting.indexWhere((task) => task.key == _key);
    if (_active.isNotEmpty) {
      if (_active.length == 1 &&
          match >= 0 &&
          (_active.single.canOverlap?.call() ?? false) &&
          (_waiting[match].canOverlap?.call() ?? false)) {
        _start(match);
      }
      return;
    }
    if (match >= 0) {
      _start(match);
    } else if (_resident == null) {
      _key = _waiting.first.key;
      _start(0);
    } else {
      _switching = _evict().whenComplete(() {
        _switching = null;
        _dispatch();
      });
    }
  }

  void _start(int index) {
    final task = _waiting.removeAt(index);
    _active.add(task);
    unawaited(
      task.run().whenComplete(() {
        _active.remove(task);
        _dispatch();
      }),
    );
    _dispatch();
  }

  /// Called after all jobs have finished or canceled.
  Future<void> close() async {
    await _switching;
    await _evict();
  }

  Future<void> _evict() async {
    final resident = _resident;
    _resident = null;
    _key = null;
    if (resident == null) return;
    try {
      await resident.close(await resident.loading);
    } catch (_) {
      // An error closing a model must not strand the rest of the queue.
    }
  }
}

class _ResidentModel {
  _ResidentModel(this.loading, this.close);
  final Future<Object> loading;
  final Future<void> Function(Object) close;
}

class _ModelUse {
  _ModelUse(this.key, this.isCancelled, this.canOverlap, this.run, this.cancel);
  final Object key;
  final bool Function()? isCancelled;
  final bool Function()? canOverlap;
  final Future<void> Function() run;
  final void Function() cancel;
}
