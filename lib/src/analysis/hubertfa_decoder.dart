import 'dart:math' as math;
import 'dart:typed_data';

import 'hubertfa_lexicon.dart';

const hubertFaFrameSeconds = 0.01;

/// The v5 export's frame scores, laid out as [1, vocabulary, frames],
/// and boundary scores, laid out as [1, frames].
class HubertFaLogits {
  HubertFaLogits(this.phones, this.edges);

  final Float32List phones;
  final Float32List edges;
}

class AcousticSpan {
  const AcousticSpan(this.start, this.end, this.confidence);

  final double start, end, confidence;
}

/// Finds a monotonic path through the given phones, with an optional SP
/// between tokens, using HuBERTFA's frame log probabilities and learned
/// boundary probabilities. Adapted from HubertFA v0.0.7's AlignmentDecoder
/// (wolfgitpr/HubertFA, Apache-2.0). Score the destination at each frame
/// and use each edge once, so one onset cannot split identical vowels.
class HubertFaDecoder {
  HubertFaDecoder(List<List<int>> transcript)
    : _states = [
        (silencePhone, -1),
        for (final (token, phones) in transcript.indexed) ...[
          for (final phone in phones) (phone, phone == silencePhone ? -1 : token),
          (silencePhone, -1),
        ],
      ],
      _tokenCount = transcript.length;

  final List<(int, int)> _states;
  final int _tokenCount;

  /// Times are relative to the clip. [pins] force the start of a token
  /// to a frame; [anchors] give a small preference to the LRC word times.
  List<AcousticSpan>? decode(
    HubertFaLogits logits, {
    required int vocabularySize,
    required int frames,
    Map<int, double> pins = const {},
    Map<int, double> anchors = const {},
  }) {
    final stride = logits.edges.length;
    if (frames > stride ||
        logits.phones.length != stride * vocabularySize ||
        !logits.phones.every((v) => v.isFinite) ||
        !logits.edges.every((v) => v.isFinite)) {
      throw const FormatException('HuBERTFA 返回了无效的音素或边界分数');
    }
    if (_tokenCount == 0 || frames < _states.where((s) => s.$1 != silencePhone).length) return null;
    final count = _states.length;
    final entryFrames = <int, int>{};
    final entryTimes = <int, double>{};
    for (var s = 1; s < count; s++) {
      final token = _states[s].$2;
      if (token < 0 || _states[s - 1].$2 == token) continue;
      // The first phone after an internal SP still belongs to the same
      // token. Attach the timestamp only to the first state for that token.
      if (s > 1 && _states[s - 2].$2 == token) continue;
      if (pins[token] case final pin?) entryFrames[s] = (pin / hubertFaFrameSeconds).round();
      if (anchors[token] case final time?) entryTimes[s] = time;
    }

    final phoneIds = _states.map((s) => s.$1).toSet();
    final frameLog = List<double>.filled(vocabularySize, 0);
    double unknownLog = 0;
    void emissions(int t) {
      double score(int id) => logits.phones[id * stride + t];
      if (phoneIds.contains(unknownPhone)) {
        // An OOV token may use any non-SP model phone. A small penalty
        // favours the known sequence when the two compete for a frame.
        unknownLog = double.negativeInfinity;
        for (var id = 1; id < vocabularySize; id++) {
          unknownLog = math.max(unknownLog, score(id));
        }
        unknownLog -= 0.7;
      }
      double at(int id) => id == unknownPhone ? unknownLog : score(id);
      final peak = phoneIds.map(at).reduce(math.max);
      final norm = peak + math.log(phoneIds.fold(0.0, (sum, id) => sum + math.exp(at(id) - peak)));
      for (final id in phoneIds) {
        if (id >= 0) frameLog[id] = score(id) - norm;
      }
      unknownLog -= norm;
    }

    double emission(int s) {
      final id = _states[s].$1;
      return id == unknownPhone ? unknownLog : frameLog[id];
    }

    double anchorCost(int s, int t) {
      final anchor = entryTimes[s];
      return anchor == null ? 0 : 8 * math.max(0.0, (t * hubertFaFrameSeconds - anchor).abs() - 0.12);
    }

    final edges = Float64List(frames);
    for (var t = 0; t < frames; t++) {
      edges[t] = 1 / (1 + math.exp(-logits.edges[t]));
    }
    final back = Uint8List(count * frames);
    var prev = List<double>.filled(count, double.negativeInfinity);
    var next = List<double>.of(prev);
    var strongest = List<double>.of(prev);
    var nextStrongest = List<double>.of(prev);
    emissions(0);
    prev[0] = strongest[0] = emission(0);
    if ((entryFrames[1] ?? 0) == 0) {
      prev[1] = emission(1) - anchorCost(1, 0);
      strongest[1] = emission(1);
    }

    final durationWeight = frames / count;
    for (var t = 1; t < frames; t++) {
      emissions(t);
      final edge = edges[t];
      final advance = math.log(edge + 1e-6);
      final stay = math.log(1.000001 - edge);
      for (var s = 0; s < count; s++) {
        final forced = entryFrames[s];
        var best = forced == null || t > forced ? prev[s] + emission(s) + stay : double.negativeInfinity;
        var step = 0;
        if (s > 0 && (forced == null || t == forced)) {
          final cost = anchorCost(s, t);
          double transition(int from) =>
              prev[from] + emission(s) + advance + strongest[from] * durationWeight - cost;
          final adjacent = transition(s - 1);
          if (adjacent > best) {
            best = adjacent;
            step = 1;
          }
          if (s > 1 && _states[s - 1].$1 == silencePhone) {
            final skipped = transition(s - 2);
            if (skipped > best) {
              best = skipped;
              step = 2;
            }
          }
        }
        next[s] = best;
        back[t * count + s] = step;
        nextStrongest[s] = _states[s].$1 == silencePhone
            ? 0
            : step == 0
            ? math.max(strongest[s], emission(s))
            : emission(s);
      }
      (prev, next) = (next, prev);
      (strongest, nextStrongest) = (nextStrongest, strongest);
    }

    var s = prev[count - 2] > prev.last ? count - 2 : count - 1;
    if (!prev[s].isFinite) return null;
    final starts = List<double>.filled(_tokenCount, -1);
    final ends = List<double>.of(starts);
    var end = frames * hubertFaFrameSeconds;
    for (var t = frames - 1; t >= 0; t--) {
      final step = back[t * count + s];
      if (step == 0 && t > 0) continue;
      final fraction = t + 1 < frames ? (edges[t + 1] - edges[t]) / 2 : 0.0;
      final start = math.max(0.0, t + fraction) * hubertFaFrameSeconds;
      final token = _states[s].$2;
      if (token >= 0) {
        starts[token] = start;
        if (ends[token] < 0) ends[token] = end;
      }
      end = start;
      s -= step;
    }
    if (starts.any((start) => start < 0)) return null;
    return [
      for (var i = 0; i < _tokenCount; i++)
        AcousticSpan(starts[i], ends[i], _states.contains((unknownPhone, i)) ? 0.5 : 1),
    ];
  }
}
