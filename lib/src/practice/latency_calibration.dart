import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:yintrace_audio/yintrace_audio.dart';

import '../dsp/real_fft.dart';

enum LatencyCalibrationMethod { automatic, tapAlong }

sealed class LatencyCalibrationResult {
  const LatencyCalibrationResult();
}

class LatencyCalibrationReading extends LatencyCalibrationResult {
  const LatencyCalibrationReading({
    required this.route,
    required this.measurement,
    required this.totalSeconds,
    required this.systemSeconds,
  });

  final OutputRoute route;
  final bool measurement;
  final double totalSeconds;
  final double systemSeconds;

  int get offsetMs => ((totalSeconds - systemSeconds) * 1000).round();
}

enum LatencyCalibrationFailure implements LatencyCalibrationResult {
  noTestSound,
  inconsistentTestSound,
  unsteadyBeat,
  routeChanged,
  interrupted,
  noMicPermission,
  audioUnavailable,
  cancelled,
}

class LatencyCalibrationControl {
  LatencyCalibrationFailure? _failure;

  void cancel({bool interrupted = false}) {
    _failure ??= interrupted ? LatencyCalibrationFailure.interrupted : LatencyCalibrationFailure.cancelled;
  }

  void _check() {
    if (_failure case final failure?) throw failure;
  }
}

typedef LatencyCalibrationProgress = ({OutputRoute route, double fraction, int? countdown});

abstract interface class LatencyMeasurer {
  OutputRoute get outputRoute;

  Future<LatencyCalibrationResult> measure(
    LatencyCalibrationMethod method, {
    required bool measurement,
    required LatencyCalibrationControl control,
    required void Function(LatencyCalibrationProgress) onProgress,
  });
}

class PracticeLatencyMeasurer implements LatencyMeasurer {
  bool _measuring = false;

  @override
  OutputRoute get outputRoute {
    try {
      return NativeAudio.outputRoute;
    } on ArgumentError {
      // A host without the native library can still display settings.
      return OutputRoute.unknown;
    } on UnsupportedError {
      return OutputRoute.unknown;
    }
  }

  @override
  Future<LatencyCalibrationResult> measure(
    LatencyCalibrationMethod method, {
    required bool measurement,
    required LatencyCalibrationControl control,
    required void Function(LatencyCalibrationProgress) onProgress,
  }) async {
    if (_measuring) return LatencyCalibrationFailure.audioUnavailable;
    _measuring = true;
    try {
      final permission = await NativeAudio.requestMicPermission();
      control._check();
      if (permission != MicPermission.granted) return LatencyCalibrationFailure.noMicPermission;
      final (signal, capture, route, systemSeconds) = await _record(method, measurement, control, onProgress);
      final totalSeconds = await compute(_estimateDelay, (signal, capture.samples));
      control._check();
      return LatencyCalibrationReading(
        route: route,
        measurement: measurement,
        totalSeconds: totalSeconds,
        systemSeconds: systemSeconds,
      );
    } on LatencyCalibrationFailure catch (failure) {
      return control._failure ?? failure;
    } on Exception catch (_) {
      return control._failure ?? LatencyCalibrationFailure.audioUnavailable;
    } on ArgumentError catch (_) {
      return LatencyCalibrationFailure.audioUnavailable;
    } finally {
      _measuring = false;
    }
  }

  static const _poll = Duration(milliseconds: 40);

  Future<(LatencyCalibrationSignal, LatencyCalibrationCapture, OutputRoute, double)> _record(
    LatencyCalibrationMethod method,
    bool measurement,
    LatencyCalibrationControl control,
    void Function(LatencyCalibrationProgress) onProgress,
  ) async {
    final previousRoute = NativeAudio.outputRoute;
    if (NativeAudio.beginLatencyCalibration(measurement: measurement) != 0) {
      throw LatencyCalibrationFailure.audioUnavailable;
    }
    PracticeEngine? engine;
    try {
      final route = NativeAudio.outputRoute;
      if (previousRoute != OutputRoute.unknown && previousRoute != route) {
        throw LatencyCalibrationFailure.routeChanged;
      }
      final device = engine = PracticeEngine.create(mode: EngineMode.duplex);
      device.setMonitorGain(0);
      device.start();
      onProgress((route: route, fraction: 0, countdown: null));

      void checkDevice({required bool warmingUp}) {
        control._check();
        final events = device.takeAudioEvents();
        if (events & (AudioEvents.deviceLost | AudioEvents.routePortsChanged) != 0 ||
            NativeAudio.outputRoute != route) {
          throw LatencyCalibrationFailure.routeChanged;
        }
        if (events & AudioEvents.stopped != 0) throw LatencyCalibrationFailure.interrupted;
        if (!warmingUp && events & AudioEvents.routeChanged != 0) {
          throw LatencyCalibrationFailure.routeChanged;
        }
      }

      // Starting I/O can generate same-port route notifications and the
      // actual device period is only known once callbacks have run.
      final warmup = Stopwatch()..start();
      do {
        await Future<void>.delayed(_poll);
        checkDevice(warmingUp: true);
        device.flushCapture();
      } while (warmup.elapsedMilliseconds < 400);

      final systemSeconds = device.systemLatencySeconds;
      final signal = LatencyCalibrationSignal(
        method,
        device.sampleRate,
        // Keep a full search window around routes with a long system delay.
        delayStartSeconds: systemSeconds > 1 ? systemSeconds - 0.55 : 0,
      );
      device.loadTrackPcm(0, signal.pcm, 1);
      device.flushCapture();
      final capture = LatencyCalibrationCapture(signal.pcm.length);
      final overrunCount = device.captureOverruns;
      final stopwatch = Stopwatch()..start();
      device.play();
      do {
        await Future<void>.delayed(_poll);
        checkDevice(warmingUp: false);
        for (final block in device.readCapture()) {
          capture.add(block);
        }
        if (device.captureOverruns != overrunCount ||
            stopwatch.elapsedMilliseconds > (signal.durationSeconds + 3) * 1000) {
          throw LatencyCalibrationFailure.audioUnavailable;
        }
        final frame = device.positionFrame;
        onProgress((
          route: route,
          fraction: capture.complete ? 1 : frame / signal.pcm.length,
          countdown: signal.countdownAt(frame),
        ));
      } while (!capture.complete);
      return (signal, capture, route, systemSeconds);
    } finally {
      try {
        engine?.dispose(); // closes the mic before restoring the shared session
      } finally {
        if (NativeAudio.endLatencyCalibration() != 0) throw LatencyCalibrationFailure.audioUnavailable;
      }
    }
  }
}

double _estimateDelay((LatencyCalibrationSignal, Float32List) recording) => recording.$1.estimateSeconds(recording.$2);

/// The test track and the exact positions of its cues in engine frames.
class LatencyCalibrationSignal {
  LatencyCalibrationSignal(this.method, this.sampleRate, {double delayStartSeconds = 0})
    : _delayStart = (delayStartSeconds * sampleRate).round() {
    switch (method) {
      case LatencyCalibrationMethod.automatic:
        // Spaced farther apart than the search window and unevenly, so a
        // neighboring pulse can't consistently look like the same delay.
        cueFrames = [
          for (final seconds in [0.6, 1.71, 2.95, 4.09, 5.39, 6.59]) _frames(seconds),
        ];
        _cue = _tone(0.028, (t) => 2 * math.pi * (650 * t + (3800 - 650) * t * t / (2 * 0.028)));
        _window = _frames(1);
      case LatencyCalibrationMethod.tapAlong:
        _beatPeriod = _frames(1.08);
        // The first three beats are the audible count-in.
        cueFrames = [for (var i = 0; i < 15; i++) _frames(0.6) + i * _beatPeriod];
        _tonePeriod = (sampleRate / 1200).round();
        _cue = _tone(0.044, (t) => 2 * math.pi * t * sampleRate / _tonePeriod);
        _window = _frames(1);
    }
    pcm = Float32List(cueFrames.last + _delayStart + _window + _cue.length + _frames(0.1));
    for (final frame in cueFrames) {
      pcm.setRange(frame, frame + _cue.length, _cue);
    }
  }

  final LatencyCalibrationMethod method;
  final int sampleRate;
  late final List<int> cueFrames;
  late final Float32List pcm;
  late final Float32List _cue;
  final int _delayStart;
  late final int _window;
  late final int _beatPeriod;
  late final int _tonePeriod;

  int _frames(double seconds) => (seconds * sampleRate).round();

  double get durationSeconds => pcm.length / sampleRate;

  int? countdownAt(int frame) {
    if (method != LatencyCalibrationMethod.tapAlong || frame >= cueFrames[3]) return null;
    final next = (frame - cueFrames.first) ~/ _beatPeriod;
    return 3 - math.max(0, next);
  }

  Float32List _tone(double seconds, double Function(double) phase) {
    final tone = Float32List(_frames(seconds));
    for (var i = 0; i < tone.length; i++) {
      final fade = math.sin(math.pi * i / (tone.length - 1));
      tone[i] = 0.24 * fade * fade * math.sin(phase(i / sampleRate)); // below -12 dBFS
    }
    return tone;
  }

  double estimateSeconds(Float32List samples) {
    if (samples.length < pcm.length) throw LatencyCalibrationFailure.audioUnavailable;
    final frames = switch (method) {
      LatencyCalibrationMethod.automatic => _findPulses(samples),
      LatencyCalibrationMethod.tapAlong => _findTaps(samples),
    };
    return frames / sampleRate;
  }

  double _findPulses(Float32List samples) {
    final fft = RealFft(1 << (_window + _cue.length - 1).bitLength);
    final templateRe = Float64List(fft.bins), templateIm = Float64List(fft.bins);
    final re = Float64List(fft.bins), im = Float64List(fft.bins);
    final correlation = Float64List(fft.n);
    fft.forward(_cue, templateRe, templateIm);
    final cueEnergy = _cue.fold(0.0, (sum, s) => sum + s * s);
    final delays = <double>[];
    for (final cue in cueFrames) {
      final start = cue + _delayStart;
      fft.forward(samples, re, im, start);
      for (var i = 0; i < fft.bins; i++) {
        // X × conj(template) gives cross-correlation in the time domain.
        final real = re[i], imaginary = im[i];
        re[i] = real * templateRe[i] + imaginary * templateIm[i];
        im[i] = imaginary * templateRe[i] - real * templateIm[i];
      }
      fft.inverse(re, im, correlation);

      var energy = 0.0;
      for (var i = start; i < start + _cue.length; i++) {
        energy += samples[i] * samples[i];
      }
      // Normalize by local microphone level to work even at low volume.
      var bestScore = 0.48;
      int? best;
      for (var lag = 0; lag <= _window; lag++) {
        if (energy > 1e-10) {
          final score = correlation[lag].abs() / math.sqrt(cueEnergy * energy);
          if (score > bestScore) {
            bestScore = score;
            best = lag;
          }
        }
        if (lag < _window) {
          final entering = samples[start + lag + _cue.length], leaving = samples[start + lag];
          energy += entering * entering - leaving * leaving;
        }
      }
      if (best != null) delays.add((_delayStart + best).toDouble());
    }
    // At least four of the six pulses must be detected and their delays
    // must all agree within 4 ms before reporting the median.
    if (delays.length < 4) throw LatencyCalibrationFailure.noTestSound;
    delays.sort();
    if (delays.last - delays.first > _frames(0.004)) {
      throw LatencyCalibrationFailure.inconsistentTestSound;
    }
    return _medianSorted(delays);
  }

  double _findTaps(Float32List samples) {
    final hop = _frames(0.004);
    final levels = Float64List(samples.length ~/ hop);
    final unfilteredPower = Float64List(levels.length);
    for (var i = 0; i < levels.length; i++) {
      var power = 0.0;
      var raw = 0.0;
      for (var j = math.max(_tonePeriod, i * hop); j < (i + 1) * hop; j++) {
        // Differencing one cue period apart suppresses leaked headphone
        // tones and slow background noise; a clap or consonant is broadband.
        final value = samples[j] - samples[j - _tonePeriod];
        power += value * value;
        raw += samples[j] * samples[j];
      }
      levels[i] = math.sqrt(power / hop);
      unfilteredPower[i] = raw / hop;
    }
    final floor = _medianSorted(levels.toList()..sort());
    final high = math.max(0.0005, floor * 2.8);
    final low = high * 0.65;
    final onsets = <int>[];
    var quiet = true;
    var last = -sampleRate;
    for (var i = 1; i < levels.length; i++) {
      if (levels[i] <= low) quiet = true;
      if (!quiet || levels[i] < high) continue;
      quiet = false;
      var begin = i;
      // Walk back to the quieter edge of this transient, at most 20 ms.
      while (begin > math.max(0, i - 5) && levels[begin - 1] > low) {
        begin--;
      }
      // A loud leaked cue can still cross the threshold at its fade edges.
      // Over the whole cue it loses most of its energy in the difference.
      var remaining = 0.0, original = 0.0;
      final end = math.min(levels.length, begin + _cue.length ~/ hop + 2);
      for (var j = begin; j < end; j++) {
        remaining += levels[j] * levels[j];
        original += unfilteredPower[j];
      }
      if (remaining < original * 0.12) continue;
      final frame = begin * hop + hop ~/ 2;
      if (frame - last < _frames(0.16)) continue;
      onsets.add(frame);
      last = frame;
    }

    final delays = <double>[];
    // Ignore three count-in beats, then the first two attempts while the
    // singer settles into the rhythm. Each beat needs a single clear onset.
    for (final beat in cueFrames.skip(5)) {
      final start = beat + _delayStart;
      final hits = onsets.where((frame) => frame >= start && frame <= start + _window);
      if (hits.length == 1) delays.add((hits.single - beat).toDouble());
    }
    if (delays.length < 8) throw LatencyCalibrationFailure.unsteadyBeat;
    delays.sort();
    final median = _medianSorted(delays);
    final deviations = [for (final delay in delays) (delay - median).abs()]..sort();
    final mad = _medianSorted(deviations);
    // 20 ms MAD allows normal beat-to-beat human jitter (plus 4 ms
    // envelope sampling), but rejects aiming for different parts of a beat.
    if (mad > _frames(0.020)) throw LatencyCalibrationFailure.unsteadyBeat;
    final limit = (3 * mad).clamp(_frames(0.025), _frames(0.050));
    final inliers = delays.where((delay) => (delay - median).abs() <= limit).toList();
    if (inliers.length < 8) throw LatencyCalibrationFailure.unsteadyBeat;
    return _medianSorted(inliers);
  }
}

double _medianSorted(List<double> sorted) {
  final middle = sorted.length ~/ 2;
  return sorted.length.isOdd ? sorted[middle] : (sorted[middle - 1] + sorted[middle]) / 2;
}

/// Copies only contiguous playing blocks, in the same song-frame coordinates
/// that LivePitchTracker and TakeRecorder use to subtract the delay.
class LatencyCalibrationCapture {
  LatencyCalibrationCapture(int frames) : samples = Float32List(frames);

  final Float32List samples;
  int _end = 0;
  bool get complete => _end == samples.length;

  void add(CaptureBlock block) {
    if (!block.playing || complete) return;
    if (block.songFrame != _end) throw LatencyCalibrationFailure.audioUnavailable;
    final end = math.min(samples.length, _end + block.samples.length);
    samples.setRange(_end, end, block.samples);
    _end = end;
  }
}
