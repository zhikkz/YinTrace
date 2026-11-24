import '../export/mixdown.dart';

/// A take the singer kept: their voice on the song's timeline (a mono audio
/// file in the song's `takes` folder) and how they like it mixed.
class Recording {
  Recording({
    required this.id,
    required this.createdAt,
    required this.file,
    required this.start,
    required this.duration,
    this.score,
    MixSettings? mix,
  }) : mix = mix ?? MixSettings();

  final String id;
  final DateTime createdAt;

  /// File name inside the song's takes folder.
  final String file;

  /// Song time (seconds) at which the audio starts.
  final double start;

  /// Length of the audio (seconds).
  final double duration;

  /// Score of the run it came from, if any.
  final double? score;

  MixSettings mix;

  double get end => start + duration;
  int get transpose => mix.transpose;

  Map<String, dynamic> toJson() => {
    'id': id,
    'createdAt': createdAt.toIso8601String(),
    'file': file,
    'start': start,
    'duration': duration,
    if (score != null && !score!.isNaN) 'score': score,
    'mix': mix.toJson(),
  };

  factory Recording.fromJson(Map<String, dynamic> j) => Recording(
    id: j['id'] as String,
    createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
    file: j['file'] as String,
    start: (j['start'] as num).toDouble(),
    duration: (j['duration'] as num).toDouble(),
    score: (j['score'] as num?)?.toDouble(),
    mix: j['mix'] is Map ? MixSettings.fromJson((j['mix'] as Map).cast<String, dynamic>()) : null,
  );
}
