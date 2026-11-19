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
///
/// Two additions for sung lines, where a held vowel is often heard as
/// another one (on a commercial song the model heard a long "ai" as the
/// "e" of the character before it, and gave that character the next two
/// characters' notes):
/// - a token shorter than [minTokenFrames] costs [shortTokenCost] per
///   missing frame, so the last characters of a line are not squeezed into
///   a few frames of whatever comes after them;
/// - a token other than the line's last one costs [longTokenCost] per frame
///   beyond [longTokenFrames]: a character in the middle of a line rarely
///   holds for longer, the last one often does.
///
/// The [guard] last tokens of the transcript are the start of the next
/// line, which the clip reaches into: with them the next line's first
/// syllable is not taken for the end of this one. The path may end before
/// them (when the next line starts later than the clip), and they are not
/// in the result.
class HubertFaDecoder {
  HubertFaDecoder(List<List<int>> transcript, {this.guard = 0})
    : assert(guard >= 0 && guard <= transcript.length),
      _states = [
        (silencePhone, -1),
        for (final (token, phones) in transcript.indexed) ...[
          for (final phone in phones) (phone, phone == silencePhone ? -1 : token),
          (silencePhone, -1),
        ],
      ],
      _tokenCount = transcript.length;

  final List<(int, int)> _states;
  final int _tokenCount;
  final int guard;

  static const minTokenFrames = 6;
  static const shortTokenCost = 1.5;
  static const longTokenFrames = 110;
  static const longTokenCost = 0.15;

  /// Times are relative to the clip. [pins] force the start of a token
  /// to a frame; [anchors] give a small preference to the LRC word times.
  /// Returns the spans of the tokens before the [guard] ones.
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
    final real = _tokenCount - guard;
    if (real <= 0 || frames < _states.where((s) => s.$1 != silencePhone && s.$2 < real).length) return null;
    final count = _states.length;
    final entryFrames = <int, int>{};
    final entryTimes = <int, double>{};
    final entry = List<bool>.filled(count, false);
    for (var s = 1; s < count; s++) {
      final token = _states[s].$2;
      if (token < 0 || _states[s - 1].$2 == token) continue;
      // The first phone after an internal SP still belongs to the same
      // token. Attach the timestamp only to the first state for that token.
      if (s > 1 && _states[s - 2].$2 == token) continue;
      entry[s] = true;
      if (pins[token] case final pin?) entryFrames[s] = (pin / hubertFaFrameSeconds).round();
      if (anchors[token] case final time?) entryTimes[s] = time;
    }
    // Leaving these states ends their token; staying in these costs once
    // the token is long.
    final last = List<bool>.generate(
      count,
      (s) => _states[s].$2 >= 0 && (s + 1 == count || _states[s + 1].$2 != _states[s].$2),
    );
    final notLast = List<bool>.generate(count, (s) => _states[s].$2 >= 0 && _states[s].$2 < real - 1);

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
    // Frames since the token of the state was entered, on the best path.
    var length = Int32List(count);
    var nextLength = Int32List(count);
    emissions(0);
    prev[0] = strongest[0] = emission(0);
    if ((entryFrames[1] ?? 0) == 0) {
      prev[1] = emission(1) - anchorCost(1, 0);
      strongest[1] = emission(1);
      length[1] = 1;
    }
    double leaving(int s) =>
        last[s] && length[s] < minTokenFrames ? shortTokenCost * (minTokenFrames - length[s]) : 0;

    final durationWeight = frames / count;
    for (var t = 1; t < frames; t++) {
      emissions(t);
      final edge = edges[t];
      final advance = math.log(edge + 1e-6);
      final stay = math.log(1.000001 - edge);
      for (var s = 0; s < count; s++) {
        final forced = entryFrames[s];
        var best = forced == null || t > forced
            ? prev[s] + emission(s) + stay - (notLast[s] && length[s] >= longTokenFrames ? longTokenCost : 0)
            : double.negativeInfinity;
        var step = 0;
        if (s > 0 && (forced == null || t == forced)) {
          final cost = anchorCost(s, t);
          double transition(int from) =>
              prev[from] + emission(s) + advance + strongest[from] * durationWeight - cost - leaving(from);
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
        nextLength[s] = entry[s] && step != 0 ? 1 : length[s - step] + 1;
      }
      (prev, next) = (next, prev);
      (strongest, nextStrongest) = (nextStrongest, strongest);
      (length, nextLength) = (nextLength, length);
    }

    // The path ends on the last phone or the final SP; with a guard also
    // on the SP after this line: then the next line has not started yet,
    // and this line's last syllable must not end where the clip does.
    final ends = [count - 2, count - 1];
    if (guard > 0) ends.add(_states.indexWhere((state) => state.$2 == real) - 1);
    var s = ends.reduce((a, b) => prev[b] > prev[a] ? b : a);
    if (!prev[s].isFinite) return null;
    final starts = List<double>.filled(_tokenCount, -1);
    final ends_ = List<double>.of(starts);
    var end = frames * hubertFaFrameSeconds;
    for (var t = frames - 1; t >= 0; t--) {
      final step = back[t * count + s];
      if (step == 0 && t > 0) continue;
      final fraction = t + 1 < frames ? (edges[t + 1] - edges[t]) / 2 : 0.0;
      final start = math.max(0.0, t + fraction) * hubertFaFrameSeconds;
      final token = _states[s].$2;
      if (token >= 0) {
        starts[token] = start;
        if (ends_[token] < 0) ends_[token] = end;
      }
      end = start;
      s -= step;
    }
    if (starts.take(real).any((start) => start < 0)) return null;
    return [
      for (var i = 0; i < real; i++)
        AcousticSpan(starts[i], ends_[i], _states.contains((unknownPhone, i)) ? 0.5 : 1),
    ];
  }
}
