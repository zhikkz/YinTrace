import 'dart:math' as math;

/// A sustained pitch inside a character.
class RefNote {
  RefNote({required this.start, required this.end, required this.midi});

  double start;
  double end;

  /// Median MIDI pitch of the note.
  double midi;

  double get duration => end - start;

  Map<String, dynamic> toJson() => {'s': _r(start), 'e': _r(end), 'm': _r(midi, 100)};

  factory RefNote.fromJson(Map<String, dynamic> j) => RefNote(
      start: (j['s'] as num).toDouble(),
      end: (j['e'] as num).toDouble(),
      midi: (j['m'] as num).toDouble());
}

/// One sung character (or word) with its time span and notes.
class RefToken {
  RefToken({
    required this.text,
    required this.start,
    required this.end,
    required this.notes,
    this.spaceBefore = false,
    this.confidence = 1,
  });

  final String text;
  double start;
  double end;
  List<RefNote> notes;
  final bool spaceBefore;

  /// How sure the aligner was about this token's boundaries (0..1).
  double confidence;

  double get duration => end - start;
  bool get hasPitch => notes.isNotEmpty;

  /// Duration weighted mean pitch (NaN without notes).
  double get meanMidi {
    if (notes.isEmpty) return double.nan;
    var s = 0.0, w = 0.0;
    for (final n in notes) {
      s += n.midi * n.duration;
      w += n.duration;
    }
    return w > 0 ? s / w : notes.first.midi;
  }

  Map<String, dynamic> toJson() => {
        't': text,
        's': _r(start),
        'e': _r(end),
        if (spaceBefore) 'sp': true,
        'c': _r(confidence, 100),
        'n': [for (final n in notes) n.toJson()],
      };

  factory RefToken.fromJson(Map<String, dynamic> j) => RefToken(
        text: j['t'] as String,
        start: (j['s'] as num).toDouble(),
        end: (j['e'] as num).toDouble(),
        spaceBefore: j['sp'] == true,
        confidence: (j['c'] as num?)?.toDouble() ?? 1,
        notes: [for (final n in j['n'] as List) RefNote.fromJson(n as Map<String, dynamic>)],
      );
}

class RefLine {
  RefLine({required this.index, required this.text, required this.lrcStart, this.lrcEnd, required this.tokens});

  final int index;
  final String text;

  /// Time stamp typed by the user.
  final double lrcStart;
  final double? lrcEnd;
  final List<RefToken> tokens;

  double get start => tokens.isEmpty ? lrcStart : tokens.first.start;
  double get end => tokens.isEmpty ? (lrcEnd ?? lrcStart) : tokens.last.end;

  Iterable<RefNote> get notes => tokens.expand((t) => t.notes);

  Map<String, dynamic> toJson() => {
        'i': index,
        'text': text,
        'ls': _r(lrcStart),
        if (lrcEnd != null) 'le': _r(lrcEnd!),
        'tokens': [for (final t in tokens) t.toJson()],
      };

  factory RefLine.fromJson(Map<String, dynamic> j) => RefLine(
        index: (j['i'] as num).toInt(),
        text: j['text'] as String,
        lrcStart: (j['ls'] as num).toDouble(),
        lrcEnd: (j['le'] as num?)?.toDouble(),
        tokens: [for (final t in j['tokens'] as List) RefToken.fromJson(t as Map<String, dynamic>)],
      );
}

/// Everything the practice screen needs to know about the target melody.
class SongReference {
  SongReference({required this.lines, required this.duration});

  final List<RefLine> lines;
  final double duration;

  Iterable<RefNote> get notes => lines.expand((l) => l.notes);
  Iterable<RefToken> get tokens => lines.expand((l) => l.tokens);

  /// Pitch range of the melody (MIDI), padded a little.
  (double, double) get pitchRange {
    var lo = double.infinity, hi = -double.infinity;
    for (final n in notes) {
      lo = math.min(lo, n.midi);
      hi = math.max(hi, n.midi);
    }
    if (lo > hi) return (55, 79);
    return (lo, hi);
  }

  /// The line playing at [t] (or the next one), -1 after the last line.
  int lineIndexAt(double t) {
    for (var i = 0; i < lines.length; i++) {
      final next = i + 1 < lines.length ? lines[i + 1].start : double.infinity;
      if (t < next) return i;
    }
    return lines.isEmpty ? -1 : lines.length - 1;
  }

  /// The reference note sounding at [t], if any.
  RefNote? noteAt(double t) {
    for (final l in lines) {
      if (t < l.start - 0.5) break;
      if (t > l.end + 0.5) continue;
      for (final n in l.notes) {
        if (t >= n.start && t < n.end) return n;
      }
    }
    return null;
  }

  Map<String, dynamic> toJson() => {
        'version': 1,
        'duration': _r(duration),
        'lines': [for (final l in lines) l.toJson()],
      };

  factory SongReference.fromJson(Map<String, dynamic> j) => SongReference(
        duration: (j['duration'] as num).toDouble(),
        lines: [for (final l in j['lines'] as List) RefLine.fromJson(l as Map<String, dynamic>)],
      );
}

double _r(double v, [int scale = 1000]) => (v * scale).roundToDouble() / scale;
