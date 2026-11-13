/// Metadata of a song in the local practice library.
class SongMeta {
  SongMeta({
    required this.id,
    required this.title,
    this.artist = '',
    required this.createdAt,
    required this.duration,
    required this.lyrics,
    required this.vocalsFile,
    this.accompanimentFile,
    this.originalFile,
    this.separated = true,
    this.modelInfo = const {},
    this.bestScore,
    this.lastScore,
    this.practiceCount = 0,
    this.lastPracticedAt,
  });

  final String id;
  String title;
  String artist;
  final DateTime createdAt;

  /// Length in seconds.
  final double duration;

  /// The timed lyrics as typed by the user (LRC).
  String lyrics;

  /// File names inside the song directory.
  final String vocalsFile;
  final String? accompanimentFile;
  final String? originalFile;

  /// Whether the vocals were separated in the app (vs. imported as is).
  final bool separated;

  /// Names of the models used for separation.
  final Map<String, String> modelInfo;

  double? bestScore;
  double? lastScore;
  int practiceCount;
  DateTime? lastPracticedAt;

  Map<String, dynamic> toJson() => {
        'format': 'yintrace-song',
        'version': 1,
        'id': id,
        'title': title,
        'artist': artist,
        'createdAt': createdAt.toIso8601String(),
        'duration': duration,
        'lyrics': lyrics,
        'vocalsFile': vocalsFile,
        if (accompanimentFile != null) 'accompanimentFile': accompanimentFile,
        if (originalFile != null) 'originalFile': originalFile,
        'separated': separated,
        'modelInfo': modelInfo,
        if (bestScore != null) 'bestScore': bestScore,
        if (lastScore != null) 'lastScore': lastScore,
        'practiceCount': practiceCount,
        if (lastPracticedAt != null) 'lastPracticedAt': lastPracticedAt!.toIso8601String(),
      };

  factory SongMeta.fromJson(Map<String, dynamic> j) => SongMeta(
        id: j['id'] as String,
        title: j['title'] as String? ?? '未命名',
        artist: j['artist'] as String? ?? '',
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '') ?? DateTime.fromMillisecondsSinceEpoch(0),
        duration: (j['duration'] as num?)?.toDouble() ?? 0,
        lyrics: j['lyrics'] as String? ?? '',
        vocalsFile: j['vocalsFile'] as String,
        accompanimentFile: j['accompanimentFile'] as String?,
        originalFile: j['originalFile'] as String?,
        separated: j['separated'] as bool? ?? true,
        modelInfo: (j['modelInfo'] as Map?)?.map((k, v) => MapEntry('$k', '$v')) ?? const {},
        bestScore: (j['bestScore'] as num?)?.toDouble(),
        lastScore: (j['lastScore'] as num?)?.toDouble(),
        practiceCount: (j['practiceCount'] as num?)?.toInt() ?? 0,
        lastPracticedAt: DateTime.tryParse(j['lastPracticedAt'] as String? ?? ''),
      );
}

/// One finished practice run.
class PracticeRecord {
  PracticeRecord({
    required this.at,
    required this.score,
    required this.lineScores,
    this.loopLine,
    this.durationSeconds = 0,
  });

  final DateTime at;
  final double score;

  /// Line index -> score (0..100) for the lines that were sung.
  final Map<int, double> lineScores;

  /// Set when the run looped a single line.
  final int? loopLine;
  final double durationSeconds;

  Map<String, dynamic> toJson() => {
        'at': at.toIso8601String(),
        'score': score,
        'lines': lineScores.map((k, v) => MapEntry('$k', (v * 10).round() / 10)),
        if (loopLine != null) 'loop': loopLine,
        'dur': durationSeconds,
      };

  factory PracticeRecord.fromJson(Map<String, dynamic> j) => PracticeRecord(
        at: DateTime.parse(j['at'] as String),
        score: (j['score'] as num).toDouble(),
        lineScores: (j['lines'] as Map).map((k, v) => MapEntry(int.parse('$k'), (v as num).toDouble())),
        loopLine: (j['loop'] as num?)?.toInt(),
        durationSeconds: (j['dur'] as num?)?.toDouble() ?? 0,
      );
}
