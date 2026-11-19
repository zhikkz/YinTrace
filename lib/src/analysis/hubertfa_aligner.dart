import 'dart:async';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter_onnxruntime/flutter_onnxruntime.dart';

import 'hubertfa_decoder.dart';
import 'hubertfa_lexicon.dart';
import 'lrc.dart';
import 'lyrics_language.dart';
import 'manual_timing.dart';
import 'pitch_track.dart';
import 'reference.dart';
import 'reference_notes.dart';

typedef _LineMatch = ({List<AcousticSpan> spans, Map<int, double> pins, double tailLimit, bool hasAlignment});

/// Runs the v0.0.7 model on one mono 44.1 kHz clip per LRC line. The graph
/// contains HuBERT's own resampling to 16 kHz and returns 10 ms frame scores.
class HubertFaAligner {
  HubertFaAligner(this.lexicon, this.infer);

  final HubertFaLexicon lexicon;
  final Future<HubertFaLogits> Function(Float32List waveform) infer;

  static const sampleRate = 44100;
  static const _samplesPerFrame = 441;
  static const padding = 0.4;
  static const _maxInferenceSeconds = 20.0;

  /// A line is aligned in a clip of at most [_lineLengthFactor] times its
  /// characters at the song's pace ([secondsPerToken]), and at least
  /// [_minLineSeconds].
  static const _lineLengthFactor = 1.8;
  static const _minLineSeconds = 3.0;

  /// A character shorter than this after a long one gets a share of it.
  static const _squeezedSeconds = 0.08;
  static const defaultSecondsPerToken = 0.6;

  /// The time the singer takes per character: the median over the lines
  /// that another line follows within 12 s (start, end, tokens).
  static double secondsPerToken(Iterable<(double, double?, int)> lines) {
    final paces = [
      for (final (start, end, tokens) in lines)
        if (end != null && tokens > 0 && end > start && end - start < 12) (end - start) / tokens,
    ]..sort();
    return paces.isEmpty ? defaultSecondsPerToken : paces[paces.length ~/ 2];
  }
  static const _minClipSamples = 2205;

  /// Opens exactly one ONNX session for the operation and closes all native
  /// resources on success, error or cancellation.
  static Future<T> withModel<T>(
    String modelPath,
    List<LyricLine> lines,
    Future<T> Function(HubertFaAligner aligner) operation,
  ) async {
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    final model = await HubertFaModel.load(modelPath);
    try {
      return await operation(model.aligner(lexicon));
    } finally {
      await model.close();
    }
  }

  static Future<HubertFaLogits> _infer(OrtSession session, Float32List waveform) async {
    final input = await OrtValue.fromList(waveform, [1, waveform.length]);
    try {
      final outputs = await session.run({'waveform': input});
      try {
        Future<Float32List> read(String name) async {
          final value = outputs[name];
          if (value == null) throw FormatException('HuBERTFA 缺少输出 $name');
          final values = await value.asFlattenedList();
          return values is Float32List ? values : Float32List.fromList(values.cast<double>());
        }

        return HubertFaLogits(await read('ph_frame_logits'), await read('ph_edge_logits'));
      } finally {
        await Future.wait([for (final value in outputs.values) value.dispose()]);
      }
    } finally {
      await input.dispose();
    }
  }

  Future<SongReference> alignSong(
    Float32List vocal,
    PitchTrack track,
    List<LyricLine> lines, {
    Map<(int, int), double> pins = const {},
    Map<(int, int), String> readings = const {},
    FutureOr<void> Function(int done, int total)? onProgress,
  }) async {
    final duration = _duration(vocal, track);
    final language = detectLyricsLanguage(lines);
    final pace = secondsPerToken([for (final l in lines) (l.start, l.end, l.tokens.length)]);
    final matches = <_LineMatch>[];
    Map<int, V> forLine<V>(Map<(int, int), V> entries, int line) => {
      for (final MapEntry(key: (k, i), :value) in entries.entries)
        if (k == line) i: value,
    };
    for (final (i, line) in lines.indexed) {
      matches.add(await _align(
        vocal, track, duration, line, language, forLine(pins, i), forLine(readings, i),
        pace: pace, next: i + 1 < lines.length ? lines[i + 1] : null,
      ));
      await onProgress?.call(i + 1, lines.length);
    }

    // The padded clips overlap. Give the next line its detected onset,
    // or split the overlap if that would cut out the previous last word.
    final cuts = <double>[0];
    for (var i = 1; i < matches.length; i++) {
      final next = matches[i], previous = matches[i - 1];
      var cut = lines[i].start.clamp(0.0, duration);
      if (next.pins[0] case final pin?) {
        cut = pin;
      } else if (next.hasAlignment) {
        final first = next.spans.first;
        cut = first.start;
        if (previous.hasAlignment) {
          final last = previous.spans.last;
          if (last.start >= cut) {
            final left = last.start + hubertFaFrameSeconds;
            final right = math.min(last.end, first.end - hubertFaFrameSeconds);
            cut = left < right ? (left + right) / 2 : lines[i].start.clamp(first.start, last.end);
          }
        }
      }
      cuts.add(math.max(cuts.last, cut));
    }
    cuts.add(duration);
    return SongReference(
      duration: track.duration,
      language: language,
      lines: [
        for (final (i, line) in lines.indexed)
          _referenceLine(track, line, i, matches[i], cuts[i], cuts[i + 1], forLine(readings, i)),
      ],
    );
  }

  /// Replaces one line after a timing or reading edit, keeping pitch edits
  /// except on tokens explicitly restored to automatic recognition. The line
  /// may start inside the sustained tail of the line before
  /// ([lineStartLimit]); that line's last character then ends where it now
  /// starts, as [alignSong] cuts between lines. The other lines stay.
  Future<SongReference> editLine(
    Float32List vocal,
    PitchTrack track,
    LyricLine line,
    SongReference current,
    int index, {
    required Map<int, double> pins,
    required Map<int, String> readings,
    Set<int> restore = const {},
    LyricLine? next,
  }) async {
    final updated = await alignEditedLine(
      vocal, track, line, index, current.language,
      lower: lineStartLimit(current, index),
      upper: lineEndLimit(current, index),
      pins: pins, readings: readings,
      next: next,
      pace: secondsPerToken([for (final l in current.lines) (l.lrcStart, l.lrcEnd, l.tokens.length)]),
    );
    for (final (i, token) in updated.tokens.indexed) {
      if (!restore.contains(i)) token.applyCorrections(current.lines[index].tokens[i]);
    }
    final lines = [...current.lines]..[index] = updated;
    if (index > 0) lines[index - 1] = _meetNextLine(track, lines[index - 1], current.lines[index].start, updated.start);
    return SongReference(lines: lines, duration: current.duration, language: current.language);
  }

  /// [line] with its last character ending where the line after it now
  /// starts ([next], before the edit [previousNext]): its tail gives way to
  /// an earlier start, and follows the voice again up to a later one (as
  /// [_tailEnd] does on import). Returns [line] itself when nothing changes.
  static RefLine _meetNextLine(PitchTrack track, RefLine line, double previousNext, double next) {
    final last = line.tokens.lastOrNull;
    if (last == null) return line;
    final gateDb = const PitchAnalysisOptions().absoluteGateDb;
    final detected = last.hasPitch && !last.manual;
    final double end;
    if (next < last.end) {
      end = _tailEnd(track, last.start, next, next, gateDb);
    } else if (next > previousNext && detected) {
      end = math.max(last.end, _tailEnd(track, last.start, last.end, next, gateDb));
    } else {
      return line;
    }
    if (end == last.end) return line;
    final notes = detected
        ? notesInFrames(
            track,
            _frameAtOrAfter(track, last.start),
            _frameAtOrAfter(track, end),
            splitSemitones: 0.8,
            minNoteSeconds: 0.06,
          )
        : <RefNote>[];
    for (final note in notes) {
      note.end = math.min(note.end, end);
    }
    final token = RefToken(
      text: last.text,
      start: last.start,
      end: end,
      notes: notes,
      spaceBefore: last.spaceBefore,
      confidence: last.confidence,
      pinned: last.pinned,
      pinyinOverride: last.pinyinOverride,
    )..applyCorrections(last);
    return RefLine(
      index: line.index,
      hubertFa: line.hubertFa,
      text: line.text,
      lrcStart: line.lrcStart,
      lrcEnd: line.lrcEnd,
      translation: line.translation,
      tokens: [...line.tokens.take(line.tokens.length - 1), token],
    );
  }

  /// Changes the pronunciation used for one line. The neighbouring lines
  /// supply hard limits so their timing and scores can be kept as stored.
  Future<RefLine> alignEditedLine(
    Float32List vocal,
    PitchTrack track,
    LyricLine line,
    int index,
    LyricsLanguage language, {
    required double lower,
    required double upper,
    required Map<int, double> pins,
    required Map<int, String> readings,
    LyricLine? next,
    double pace = defaultSecondsPerToken,
  }) async {
    final duration = _duration(vocal, track);
    final match = await _align(vocal, track, duration, line, language, pins, readings, pace: pace, next: next);
    final end = math.min(duration, upper);
    if (!match.hasAlignment || lower >= end) {
      throw const FormatException('这句附近没有足够的人声音频');
    }
    final result = _referenceLine(track, line, index, match, lower, end, readings);
    if (result.tokens.any((token) => token.duration <= 0) || pins.keys.any((i) => result.tokens[i].pinned == null)) {
      throw const FormatException('这句的模型时间与相邻句或手动位置冲突');
    }
    return result;
  }

  static double _duration(Float32List vocal, PitchTrack track) => math.min(vocal.length / sampleRate, track.duration);

  Future<_LineMatch> _align(
    Float32List vocal,
    PitchTrack track,
    double duration,
    LyricLine line,
    LyricsLanguage language,
    Map<int, double> pins,
    Map<int, String> readings, {
    required double pace,
    LyricLine? next,
  }) async {
    final transcript = lexicon.phones(line, language, readings);
    final nominalEnd = line.end ?? line.start + 12;
    final limit = (line.end == null ? duration : nominalEnd + padding).clamp(0.0, duration);
    final start = (line.start - padding).clamp(0.0, duration);
    // A line before a long break (an interlude) is not sung for all of it:
    // what the clip hears there is backing vocals or ad-libs, and the
    // line's last characters would go to them.
    final expectedEnd = line.start + math.max(_minLineSeconds, line.tokens.length * pace * _lineLengthFactor);
    final end = math.min(math.min(nominalEnd, expectedEnd) + padding, start + _maxInferenceSeconds).clamp(start, duration);
    var left = start;
    var right = end;
    for (final pin in pins.values) {
      if (pin < 0 || pin >= duration) continue;
      final a = math.min(left, math.max(0.0, pin - padding));
      final b = math.max(right, math.min(duration, pin + padding));
      if (b - a <= _maxInferenceSeconds) (left, right) = (a, b);
    }
    final from = (left * sampleRate).floor();
    final to = math.min(vocal.length, (right * sampleRate).ceil());
    final clipStart = from / sampleRate;
    final clipEnd = to / sampleRate;
    final frames = (to - from) ~/ _samplesPerFrame;
    final relativePins = {
      for (final MapEntry(:key, :value) in pins.entries)
        if (value >= clipStart && value < clipStart + frames * hubertFaFrameSeconds) key: value - clipStart,
    };
    if (to - from >= _minClipSamples && transcript.isNotEmpty) {
      final logits = await infer(Float32List.sublistView(vocal, from, to));
      final anchors = {
        0: line.start - clipStart,
        for (final (i, t) in line.tokens.indexed)
          if (t.time case final time? when time >= clipStart && time < clipEnd) i: time - clipStart,
      };
      // The clip reaches into the next line: its first syllable is part of
      // the transcript, so that this line's last ones are not put on it.
      final guard = next != null && next.tokens.isNotEmpty && next.start < clipEnd
          ? lexicon.phones(LyricLine(start: next.start, text: next.tokens.first.text, tokens: [next.tokens.first]),
                language, const {})
          : const <List<int>>[];
      if (guard.isNotEmpty) anchors[transcript.length] = next!.start - clipStart;
      final decoder = HubertFaDecoder([...transcript, ...guard], guard: guard.length);
      List<AcousticSpan>? decode(Map<int, double> pins) =>
          decoder.decode(logits, vocabularySize: lexicon.size, frames: frames, pins: pins, anchors: anchors);
      var spans = decode(relativePins);
      var usedPins = relativePins.keys.toSet();
      if (spans == null && usedPins.isNotEmpty) {
        usedPins = const {};
        spans = decode(const {});
      }
      if (spans != null &&
          (usedPins.isNotEmpty || _hasEnergy(track, clipStart + spans.first.start, clipStart + spans.last.end))) {
        return (
          spans: [
            for (final span in spans) AcousticSpan(clipStart + span.start, clipStart + span.end, span.confidence),
          ],
          pins: {for (final key in usedPins) key: pins[key]!},
          tailLimit: math.max(limit, right),
          hasAlignment: true,
        );
      }
    }
    // Some LRCs contain timed headings, backing vocals, or lines past EOF.
    // Keep their text in the reference without assigning notes.
    final begin = line.start.clamp(0.0, duration);
    final span = math.min(math.max(0.0, limit - begin), 0.35 * line.tokens.length);
    final step = line.tokens.isEmpty ? 0.0 : span / line.tokens.length;
    return (
      spans: [for (var i = 0; i < line.tokens.length; i++) AcousticSpan(begin + i * step, begin + (i + 1) * step, 0)],
      pins: const <int, double>{},
      tailLimit: limit,
      hasAlignment: false,
    );
  }

  static bool _hasEnergy(PitchTrack track, double from, double to) {
    for (var i = _frameAtOrAfter(track, from); i < _frameAtOrAfter(track, to); i++) {
      if (track.rmsDb[i] >= const PitchAnalysisOptions().absoluteGateDb) return true;
    }
    return false;
  }

  static int _frameAtOrAfter(PitchTrack track, double time) => (time / track.hopSeconds).ceil().clamp(0, track.length);

  static RefLine _referenceLine(
    PitchTrack track,
    LyricLine line,
    int index,
    _LineMatch match,
    double from,
    double to,
    Map<int, String> readings,
  ) {
    const options = PitchAnalysisOptions();
    final starts = <double>[];
    for (final (i, span) in match.spans.indexed) {
      starts.add((match.pins[i] ?? span.start).clamp(starts.lastOrNull ?? from, to));
    }
    // A character the model barely heard, sung on the held note of the one
    // before it (two characters on one note), still gets the end of that note: a
    // character with no note at all is neither drawn nor scored.
    if (match.hasAlignment) {
      for (var i = 1; i < starts.length; i++) {
        if (match.pins.containsKey(i)) continue;
        final next = i + 1 < starts.length ? starts[i + 1] : to;
        final before = starts[i] - starts[i - 1];
        if (next - starts[i] < _squeezedSeconds && before > 5 * _squeezedSeconds) {
          starts[i] = math.max(starts[i - 1] + 0.7 * before, next - 1.5 * _squeezedSeconds);
        }
      }
    }
    final tokens = <RefToken>[];
    for (final (i, span) in match.spans.indexed) {
      final token = line.tokens[i];
      final start = starts[i];
      final next = i + 1 < starts.length ? starts[i + 1] : to;
      var end = span.end.clamp(start, next);
      if (i == starts.length - 1 && match.hasAlignment && end > start) {
        final limit = math.min(to, match.tailLimit);
        end = _tailEnd(track, start, end, limit, options.absoluteGateDb);
      }
      final notes = match.hasAlignment
          ? notesInFrames(
              track,
              _frameAtOrAfter(track, start),
              _frameAtOrAfter(track, end),
              splitSemitones: 0.8,
              minNoteSeconds: 0.06,
            )
          : <RefNote>[];
      for (final note in notes) {
        note.end = math.min(note.end, end);
      }
      tokens.add(
        RefToken(
          text: token.text,
          start: start,
          end: end,
          notes: notes,
          spaceBefore: token.spaceBefore,
          confidence: end > start ? span.confidence : 0,
          pinned: match.pins[i] == start ? match.pins[i] : null,
          pinyinOverride: readings[i],
        ),
      );
    }
    return RefLine(
      index: index,
      hubertFa: true,
      text: line.text,
      lrcStart: line.start,
      lrcEnd: line.end,
      translation: line.translation,
      tokens: tokens,
    );
  }

  /// Follow the last syllable's voiced frames across brief pitch dropouts.
  /// The first sustained loss of pitch or energy ends the syllable. The
  /// next line's first token is the latest possible end.
  static double _tailEnd(PitchTrack track, double start, double end, double limit, double absoluteGateDb) {
    final from = _frameAtOrAfter(track, start);
    final modelEnd = _frameAtOrAfter(track, end);
    final stop = _frameAtOrAfter(track, limit);
    var peakDb = absoluteGateDb;
    for (var i = from; i < modelEnd; i++) {
      if (track.voiced(i)) peakDb = math.max(peakDb, track.rmsDb[i]);
    }
    final gateDb = math.max(absoluteGateDb, peakDb - 30);
    final gap = (0.08 / track.hopSeconds).ceil();
    bool active(int i) => track.voiced(i) && track.rmsDb[i] >= gateDb;
    var last = modelEnd - 1;
    while (last >= from && !active(last)) {
      last--;
    }
    if (last < from) return end;
    for (var i = last + 1; i < stop && i - last <= gap; i++) {
      if (active(i)) last = i;
    }
    return math.min(limit, track.timeOf(last + 1));
  }
}

/// Native HuBERTFA session, independent of each song's lyrics and lexicon.
class HubertFaModel {
  HubertFaModel._(this._session);

  final OrtSession _session;

  static Future<HubertFaModel> load(String modelPath) async {
    final session = await OnnxRuntime().createSession(
      modelPath,
      options: OrtSessionOptions(
        providers: const [OrtProvider.CPU],
        intraOpNumThreads: 4,
        useArena: false,
        // Avoid an additional prepacked copy of the transformer's weights.
        sessionConfigs: const {'session.disable_prepacking': '1'},
      ),
    );
    return HubertFaModel._(session);
  }

  HubertFaAligner aligner(HubertFaLexicon lexicon) =>
      HubertFaAligner(lexicon, (waveform) => HubertFaAligner._infer(_session, waveform));

  Future<void> close() => _session.close();
}
