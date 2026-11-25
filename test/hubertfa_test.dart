import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;
import 'dart:typed_data';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/hubertfa_aligner.dart';
import 'package:yintrace/src/analysis/hubertfa_decoder.dart';
import 'package:yintrace/src/analysis/hubertfa_lexicon.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/lyrics_language.dart';
import 'package:yintrace/src/analysis/mandarin_readings.dart';
import 'package:yintrace/src/analysis/manual_timing.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/analysis/reference.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/audio/wav.dart';
import 'package:yintrace/src/import/import_pipeline.dart';
import 'package:yintrace/src/library/song_repository.dart';

const _phones = {
  'SP': 0,
  'zh/ch': 1,
  'zh/ang': 2,
  'zh/zh': 3,
  'zh/l': 4,
  'zh/e': 5,
  'zh/iao': 6,
  'zh/a': 7,
  'en/g': 8,
  'en/ow': 9,
  'ja/k': 10,
  'ja/a': 11,
  'zh/d': 12,
  'zh/t': 13,
  'zh/an': 14,
  'zh/x': 15,
  'zh/ing': 16,
  'zh/h': 17,
};
const _lyrics = '[00:00.80]长啊\n[00:02.10]了\n[00:02.70]\n';

HubertFaLogits _scores(int frames, double offset, List<(double, double, int)> spans) {
  final logits = Float32List(_phones.length * frames)..fillRange(0, _phones.length * frames, -8);
  final edges = Float32List(frames)..fillRange(0, frames, -6);
  var previous = 0;
  for (var i = 0; i < frames; i++) {
    final t = offset + i * hubertFaFrameSeconds;
    final phone = spans.where((s) => t >= s.$1 && t < s.$2).firstOrNull?.$3 ?? 0;
    logits[phone * frames + i] = 6;
    if (phone != previous) edges[i] = 5;
    previous = phone;
  }
  return HubertFaLogits(logits, edges);
}

const _pronounced = [(0.54, 0.65, 1), (0.65, 1.02, 2), (1.17, 1.56, 7), (1.91, 2.04, 4), (2.04, 2.38, 5)];

PitchTrack _track({bool quietTail = false, bool legato = false}) {
  const frames = 300;
  final midi = Float32List(frames);
  final db = Float32List(frames)..fillRange(0, frames, -100);
  for (final (start, end) in legato ? [(52, 103), (117, 255)] : [(52, 103), (117, 188), (192, 255)]) {
    midi.fillRange(start, end, 64);
    db.fillRange(start, end, -21);
  }
  if (quietTail) db.fillRange(229, 255, -65);
  return PitchTrack(hopSeconds: 0.01, midi: midi, rmsDb: db, aperiodicity: Float32List(frames));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory tmp;
  late String modelPath;
  setUp(() {
    tmp = Directory.systemTemp.createTempSync('hubertfa');
    modelPath = '${tmp.path}/model.onnx';
    File('${tmp.path}/vocab.json').writeAsStringSync(
      jsonEncode({
        'vocab': _phones,
        'vocab_size': _phones.length,
        'language_prefix': true,
        'dictionaries': {'zh': 'zh.txt', 'en': 'en.txt', 'ja': 'ja.txt'},
      }),
    );
    File('${tmp.path}/zh.txt').writeAsStringSync('chang\tch ang\nzhang\tzh ang\nle\tl e\nliao\tl iao\na\ta\n');
    File('${tmp.path}/en.txt').writeAsStringSync('go\tg ow\n');
    File('${tmp.path}/ja.txt').writeAsStringSync('ka\tk a\n');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  test('G2P uses phrase context and maps overrides by token, including repeated characters', () async {
    final readings = await MandarinReadings.load();
    expect(readings.forTokens(tokenize('長大 了解 還給')), {0: 'zhang', 1: 'da', 2: 'liao', 3: 'jie', 4: 'huan', 5: 'gei'});
    expect(normalizePinyin('LǙ'), 'lv');
    expect(normalizePinyin('zhang3'), 'zhang');
    final lines = parseLrc('[00:00]长长 go\n[00:02]カ').lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    expect(lexicon.phones(lines[0], LyricsLanguage.chinese, {0: 'zhǎng', 1: 'cháng'}), [
      [3, 2],
      [1, 2],
      [8, 9],
    ]);
    expect(lexicon.phones(lines[1], LyricsLanguage.japanese, {}), [
      [10, 11],
    ]);
    expect(() => lexicon.phones(lines[0], LyricsLanguage.chinese, {1: 'bad'}), throwsFormatException);
  });

  test('the alignment worker can read all bundled Mandarin tables', () async {
    final token = RootIsolateToken.instance!;
    final tables = await MandarinReadings.bundledTables();
    final pinyin = await Isolate.run(() async {
      BackgroundIsolateBinaryMessenger.ensureInitialized(token);
      MandarinReadings.initializeWorker(() async => tables);
      final readings = await MandarinReadings.load();
      return readings.forTokens(tokenize('彈著吉他 一行淚')).values.join(' ');
    });
    expect(pinyin, 'tan zhe ji ta yi hang lei');
  });

  test('Mandarin lyrics distinguish playing an instrument and counting rows', () async {
    final readings = await MandarinReadings.load();
    for (final entry in const {
      '弹着吉他': 'tan zhe ji ta',
      '彈著鋼琴': 'tan zhe gang qin',
      '弹过琵琶': 'tan guo pi pa',
      '你彈著那把木吉他': 'ni tan zhe na ba mu ji ta',
      '弹了一夜琴': 'tan le yi ye qin',
      '看著你 聽著音樂 著名': 'kan zhe ni ting zhe yin yue zhu ming',
      '一行泪': 'yi hang lei',
      '兩行清淚': 'liang hang qing lei',
      '几行诗句': 'ji hang shi ju',
      '那一行行文字': 'na yi hang hang wen zi',
      '清淚兩行 泪成行 写下诗行': 'qing lei liang hang lei cheng hang xie xia shi hang',
      '一行诗人 诗行天下': 'yi xing shi ren shi xing tian xia',
      '重重心事 重重地敲门': 'chong chong xin shi zhong zhong de qiao men',
      '重弹旧曲 心情沉重': 'chong tan jiu qu xin qing chen zhong',
      '弹琴 子弹着火 弹药': 'tan qin zi dan zhao huo dan yao',
      '一行人 步行 行李': 'yi xing ren bu xing xing li',
      '五行相生': 'wu xing xiang sheng',
      '音樂 長大 重新开始 银行 成长': 'yin yue zhang da chong xin kai shi yin hang cheng zhang',
      '弹，吉他 弹着，吉他': 'dan ji ta dan zhe ji ta',
      '一，行泪 一行，泪': 'yi xing lei yi xing lei',
      '泪，两行': 'lei liang xing',
      '弹着go吉他 一行カ泪': 'dan zhe ji ta yi xing lei',
      '一行(いっこう)行泪': 'xing lei',
    }.entries) {
      expect(readings.forTokens(tokenize(entry.key)).values.join(' '), entry.value, reason: entry.key);
    }
  });

  test('HuBERTFA receives contextual phones unless that token has an override', () async {
    File('${tmp.path}/zh.txt').writeAsStringSync('dan\td an\ntan\tt an\nxing\tx ing\nhang\th ang\n');
    final line = parseLrc('[00:00]弹着吉他 一行泪').lines.single;
    final lexicon = await HubertFaLexicon.load(modelPath, [line]);
    final phones = lexicon.phones(line, LyricsLanguage.chinese, {});
    expect(phones[0], [13, 14]); // tan
    expect(phones[5], [17, 2]); // hang
    final overridden = lexicon.phones(line, LyricsLanguage.chinese, {0: 'dàn'});
    expect(overridden[0], [12, 14]);
    expect(overridden.skip(1), phones.skip(1));
    expect(lexicon.phones(line, LyricsLanguage.japanese, {}).expand((p) => p), everyElement(unknownPhone));
    File('${tmp.path}/zh.txt').writeAsStringSync('dan\td an\nxing\tx ing\n');
    final limited = await HubertFaLexicon.load(modelPath, [line]);
    final fallback = limited.phones(line, LyricsLanguage.chinese, {});
    expect(fallback[0], [12, 14]);
    expect(fallback[5], [15, 16]);
  });

  test('model edges distinguish repeated syllables even with no silence between them', () {
    final logits = _scores(100, 0, [(0.15, 0.82, 7)]);
    logits.edges[42] = 5;
    final result = HubertFaDecoder([
      [7],
      [7],
    ]).decode(logits, frames: 100, vocabularySize: _phones.length)!;
    expect(result.first.start, closeTo(0.15, 0.04));
    expect(result.last.start, closeTo(0.42, 0.025));
    expect(result.last.end, closeTo(0.82, 0.04));
  });

  // 长啊, and the next line starts with 啊 inside the clip. The model hears
  // this line's 啊 less clearly than the next one (a held vowel heard as
  // the one before it), so without the next line in the transcript the
  // decoder gives 长 both and puts 啊 on the next line's syllable.
  HubertFaLogits heardLess(int frames) {
    final logits = _scores(frames, 0, [(0.5, 0.6, 1), (0.6, 1.0, 2), (1.0, 1.3, 7), (2.0, 2.3, 7)]);
    for (var i = 100; i < 130; i++) {
      logits.phones[7 * frames + i] = 2;
      logits.phones[2 * frames + i] = 1;
    }
    return logits;
  }

  test('the next line\'s first syllable in the clip is not taken for this line\'s last one', () {
    const frames = 240;
    final alone = HubertFaDecoder([
      [1, 2],
      [7],
    ]).decode(heardLess(frames), frames: frames, vocabularySize: _phones.length)!;
    expect(alone.last.start, greaterThan(1.9), reason: 'the failure the guard prevents');
    final guarded = HubertFaDecoder([
      [1, 2],
      [7],
      [7],
    ], guard: 1).decode(heardLess(frames), frames: frames, vocabularySize: _phones.length, anchors: {2: 2.0})!;
    expect(guarded, hasLength(2));
    expect(guarded.first.start, closeTo(0.5, 0.03));
    expect(guarded.last.start, closeTo(1.0, 0.03));
    expect(guarded.last.end, lessThan(1.4));
  });

  test('the guard is optional: a next line that starts after the clip is not forced into it', () {
    const frames = 160;
    final logits = _scores(frames, 0, [(0.5, 0.6, 1), (0.6, 1.0, 2), (1.0, 1.3, 7)]);
    final spans = HubertFaDecoder([
      [1, 2],
      [7],
      [4, 5],
    ], guard: 1).decode(logits, frames: frames, vocabularySize: _phones.length)!;
    expect(spans, hasLength(2));
    expect(spans.last.start, closeTo(1.0, 0.03));
    expect(spans.last.end, closeTo(1.3, 0.05));
  });

  test('a line before an interlude is aligned on its own part, not on an ad-lib in the break', () async {
    final lines = parseLrc('[00:00.80]长啊\n[00:30.00]了\n').lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    const frames = 3200;
    final midi = Float32List(frames);
    final db = Float32List(frames)..fillRange(0, frames, -100);
    for (final (a, b) in [(52, 140), (800, 860)]) {
      midi.fillRange(a, b, 64);
      db.fillRange(a, b, -21);
    }
    final track = PitchTrack(hopSeconds: 0.01, midi: midi, rmsDb: db, aperiodicity: Float32List(frames));
    final widths = <double>[];
    final reference = await HubertFaAligner(lexicon, (audio) async {
      final offset = widths.isEmpty ? 0.4 : 29.6;
      widths.add(audio.length / HubertFaAligner.sampleRate);
      final n = audio.length ~/ 441 + 1;
      final logits = _scores(n, offset, [(0.5, 0.6, 1), (0.6, 1.0, 2), (1.0, 1.4, 7), (8.0, 8.6, 7)]);
      if (offset < 1) {
        for (var i = 60; i < 100; i++) {
          logits.phones[7 * n + i] = 2;
        }
      }
      return logits;
    }).alignSong(Float32List(32 * 44100), track, lines);
    // Two characters at the song's pace (0.6 s each by default), and at
    // least 3 s: the clip ends at 0.8 + 3 + 0.4 s, before the ad-lib at 8 s.
    expect(widths.first, closeTo(3.8, 0.01));
    final tokens = reference.lines.first.tokens;
    expect(tokens.last.start, closeTo(1.0, 0.05));
    expect(tokens.last.end, closeTo(1.4, 0.05));
    expect(tokens.last.notes, isNotEmpty);
  });

  test('the song\'s pace: the median time per character of lines that another line follows soon', () {
    expect(HubertFaAligner.secondsPerToken([(0, 4, 8), (4, 7, 6), (7, 40, 4), (40, null, 5)]), 0.5);
    expect(HubertFaAligner.secondsPerToken([(0, 30, 2)]), HubertFaAligner.defaultSecondsPerToken);
  });

  test('padded clips recover early starts and use pitch and energy for tails', () async {
    final lines = parseLrc(_lyrics).lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    final widths = <double>[];
    final track = _track(quietTail: true);
    final reference = await HubertFaAligner(lexicon, (audio) async {
      final offset = widths.isEmpty ? 0.4 : 1.7;
      widths.add(audio.length / HubertFaAligner.sampleRate);
      return _scores(audio.length ~/ 441 + 1, offset, _pronounced);
    }).alignSong(Float32List(3 * 44100), track, lines, pins: {(0, 1): 1.15}, readings: {(1, 0): 'le'});
    expect(widths, [closeTo(2.1, 0.001), closeTo(1.3, 0.001)]);
    expect(reference.lines.first.start, closeTo(0.54, 0.04));
    expect(reference.lines.first.tokens.last.pinned, 1.15);
    expect(reference.lines.first.end, closeTo(1.88, 0.03), reason: 'extends the sustained vowel past model SP');
    expect(reference.lines.first.end, lessThanOrEqualTo(reference.lines.last.start));
    expect(reference.lines.last.end, closeTo(2.29, 0.02), reason: 'energy falls before pitch disappears');
    expect(reference.lines.first.notes, isNotEmpty);
    final saved = SongReference.fromJson(reference.toJson());
    final moved = parseLrc('[00:00.20]开头\n$_lyrics').lines;
    expect(carriedPinyin(saved, moved), {(2, 0): 'le'});
  });

  test('editing and restoring the first line preserves the quiet tail and corrections of the second', () async {
    final lines = parseLrc(_lyrics).lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    final vocal = Float32List(3 * 44100), track = _track(quietTail: true);
    var calls = 0;
    final aligner = HubertFaAligner(lexicon, (clip) async =>
        _scores(clip.length ~/ 441 + 1, calls++ == 1 ? 1.7 : 0.4, _pronounced));
    final original = await aligner.alignSong(vocal, track, lines, readings: {(0, 0): 'chang'});
    original.lines.last.tokens.single.transpose(2);
    final untouched = original.lines.last.toJson();
    expect(original.lines.first.tokens.first.corrected, isTrue);
    final pin = original.lines.first.start + 0.020;
    final edited = await aligner.editLine(vocal, track, lines.first, original, 0,
        pins: {0: pin}, readings: {0: 'chang'});
    expect(edited.lines.first.tokens.first.pinned, pin);
    expect(edited.lines.last.toJson(), untouched);
    final restored = await aligner.editLine(vocal, track, lines.first, edited, 0,
        pins: {}, readings: {}, restore: {0, 1});
    expect(restored.lines.first.tokens.any((t) => t.corrected), isFalse);
    expect(restored.lines.first.start, original.lines.first.start);
    expect(restored.lines.last.toJson(), untouched);
    expect(calls, 4);
  });

  test('second line keeps its exact first pin between model frames', () async {
    final lines = parseLrc(_lyrics).lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    for (final pin in [2.111, 2.115, 2.119, 2.123]) {
      var calls = 0;
      final aligner = HubertFaAligner(lexicon, (clip) async =>
          _scores(clip.length ~/ 441 + 1, calls++ == 0 ? 0.4 : 1.7, _pronounced));
      final ref = await aligner.alignSong(Float32List(3 * 44100), _track(), lines, pins: {(1, 0): pin});
      expect(ref.lines.last.start, pin);
      expect(ref.lines.last.tokens.first.pinned, pin);
      expect(ref.lines.first.end, lessThanOrEqualTo(pin));
    }
  });

  test('a line can start earlier, inside the sustained tail of the line before, and give it back', () async {
    final lines = parseLrc(_lyrics).lines;
    final lexicon = await HubertFaLexicon.load(modelPath, lines);
    // 啊 runs legato into 了, which the model hears at 2.00 instead of 1.91.
    final vocal = Float32List(3 * 44100), track = _track(legato: true);
    const heard = [(0.54, 0.65, 1), (0.65, 1.02, 2), (1.17, 2.00, 7), (2.00, 2.10, 4), (2.10, 2.38, 5)];
    // Each clip is a view of the vocal: lay its scores out where it starts.
    final aligner = HubertFaAligner(lexicon, (clip) async =>
        _scores(clip.length ~/ 441 + 1, clip.offsetInBytes / 4 / HubertFaAligner.sampleRate, heard));
    final original = await aligner.alignSong(vocal, track, lines);
    final tail = original.lines.first.tokens.last..transpose(1);
    expect(original.lines.first.end, original.lines.last.start, reason: 'the tail reaches the late onset');
    // The editor offers what editLine can keep: into the tail, not onto 啊.
    expect(pinRange(original, 1, 0, lineOnly: true).$1, closeTo(tail.start + 0.06, 1e-9));
    expect(pinRange(original, 0, 1, lineOnly: true).$2, closeTo(original.lines.last.start - 0.06, 1e-9));

    final edited = await aligner.editLine(vocal, track, lines.last, original, 1, pins: {0: 1.91}, readings: {});
    expect(edited.lines.last.tokens.single.pinned, 1.91);
    final cut = edited.lines.first.tokens.last;
    expect(cut.end, inInclusiveRange(1.85, 1.91));
    expect(cut.notes.last.end, lessThanOrEqualTo(cut.end));
    expect(cut.shift, 1, reason: 'its pitch correction stays');
    expect(edited.lines.first.tokens.first.toJson(), original.lines.first.tokens.first.toJson());
    await expectLater(
      aligner.editLine(vocal, track, lines.last, original, 1, pins: {0: tail.start + 0.03}, readings: {}),
      throwsFormatException,
    );

    final restored = await aligner.editLine(vocal, track, lines.last, edited, 1, pins: {}, readings: {}, restore: {0});
    expect(restored.lines.last.start, original.lines.last.start);
    expect(restored.lines.first.toJson(), original.lines.first.toJson(), reason: 'the tail follows the voice again');
  });

  test('an unavailable alignment model falls back and saves the processed vocal', () async {
    final audioPath = '${tmp.path}/vocal.wav';
    writeWavFile(audioPath, Float32List(3 * 44100), 1, 44100);
    final repo = SongRepository(Directory('${tmp.path}/songs'));
    final song = await ImportPipeline(audio: const WavAudioBackend(), repository: repo,
      loadModel: (_, {required inputName, required outputName, coreML}) => throw StateError('unused'),
    ).run(ImportRequest(audioPath: audioPath, lyrics: _lyrics, title: 'test', vocalsOnly: true,
        hubertFaPath: '${tmp.path}/missing/model.onnx'));
    expect(song.modelInfo['alignment'], '音高轨迹');
    expect(song.modelInfo['alignmentModelError'], isNotEmpty);
    expect(File(repo.pathFor(song.id, song.vocalsFile)).existsSync(), isTrue);
    expect((await repo.loadReference(song.id)).lines, hasLength(2));
  });

  test('only the edited occurrence uses the override and pins keep their exact start', () async {
    final line = parseLrc('[00:00.40]长啊\n[00:01.60]').lines.single;
    final lexicon = await HubertFaLexicon.load(modelPath, [line]);
    final aligner = HubertFaAligner(
      lexicon,
      (audio) async => _scores(audio.length ~/ 441 + 1, 0, [(0.54, 0.65, 3), ..._pronounced.skip(1)]),
    );
    final result = await aligner.alignEditedLine(
      Float32List(3 * 44100),
      _track(),
      line,
      4,
      LyricsLanguage.chinese,
      lower: 0.2,
      upper: 1.6,
      pins: {1: 1.147},
      readings: {0: 'zhang'},
    );
    expect(result.index, 4);
    expect(result.tokens.first.pinyinOverride, 'zhang');
    expect(result.tokens.last.pinyinOverride, isNull);
    expect(result.tokens.last.pinned, 1.147);
    expect(result.end, lessThanOrEqualTo(1.6));
  });

  test('normal import sends each line to the same session and releases native tensors', () async {
    final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    const channel = MethodChannel('flutter_onnxruntime');
    var opens = 0, runs = 0, closes = 0, releases = 0, frames = 0;
    late HubertFaLogits result;
    messenger.setMockMethodCallHandler(channel, (call) async {
      final args = call.arguments as Map;
      switch (call.method) {
        case 'createSession':
          opens++;
          expect(args['modelPath'], modelPath);
          return {
            'sessionId': 'one',
            'inputNames': ['waveform'],
            'outputNames': ['ph_frame_logits', 'ph_edge_logits', 'ctc_logits'],
          };
        case 'createOrtValue':
          final shape = (args['shape'] as List).cast<int>();
          expect(shape.first, 1);
          final audio = args['data'] as Float32List;
          expect(audio.length, shape.last);
          frames = audio.length ~/ 441 + 1;
          result = _scores(frames, runs == 0 ? 0.4 : 1.7, _pronounced);
          return {'valueId': 'in', 'dataType': 'float32', 'shape': shape};
        case 'runInference':
          runs++;
          expect(args['sessionId'], 'one');
          expect((args['inputs'] as Map).keys.single, 'waveform');
          return {
            'ph_frame_logits': [
              'p',
              'float32',
              [1, _phones.length, frames],
            ],
            'ph_edge_logits': [
              'e',
              'float32',
              [1, frames],
            ],
            'ctc_logits': [
              'ctc',
              'float32',
              [1, _phones.length, frames],
            ],
          };
        case 'getOrtValueData':
          return {'data': args['valueId'] == 'p' ? result.phones : result.edges};
        case 'releaseOrtValue':
          releases++;
          return null;
        case 'closeSession':
          closes++;
          return null;
      }
      throw StateError(call.method);
    });
    addTearDown(() => messenger.setMockMethodCallHandler(channel, null));
    final voice = Float32List(3 * 44100);
    for (var i = 22050; i < 2.5 * 44100; i++) {
      voice[i] = 0.4 * math.sin(i * 2 * math.pi * 240 / 44100);
    }
    final audioPath = '${tmp.path}/vocal.wav';
    writeWavFile(audioPath, voice, 1, 44100);
    final repository = SongRepository(Directory('${tmp.path}/songs'));
    final progress = <int>[];
    final request = ImportRequest(
      audioPath: audioPath,
      lyrics: _lyrics,
      title: '两句',
      vocalsOnly: true,
      hubertFaPath: modelPath,
    );
    final song =
        await ImportPipeline(
          audio: const WavAudioBackend(),
          repository: repository,
          loadModel: (_, {required inputName, required outputName, coreML}) => throw StateError('unused'),
        ).run(
          ImportRequest.fromMap(request.toMap()),
          onProgress: (p) {
            if (p.stage == ImportStage.aligning && p.done != null) progress.add(p.done!);
          },
        );
    expect([opens, runs, closes, releases], [1, 2, 1, 8]);
    expect(progress, [1, 2]);
    expect(song.modelInfo['alignment'], 'HuBERTFA');
    final saved = await repository.loadReference(song.id);
    expect(saved.lines.map((l) => l.tokenText), ['长啊', '了']);
    expect(saved.lines.first.start, lessThan(0.8));
  });
}
