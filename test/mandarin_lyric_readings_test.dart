import 'dart:io';
import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/mandarin_readings.dart';

List<List<String>> _rows(String fixture) =>
    File('test/fixtures/$fixture.tsv')
        .readAsLinesSync()
        .where((line) => line.isNotEmpty && !line.startsWith('#'))
        .map((line) => line.split('\t'))
        .toList();

String _percent(int correct, int total) =>
    '${(100 * correct / total).toStringAsFixed(2)}% ($correct/$total)';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cases = _rows('mandarin_lyric_readings');

  test('Mandarin table loading and 60-line lookup timings', () async {
    final assetTimer = Stopwatch()..start();
    final tables = await MandarinReadings.bundledTables();
    assetTimer.stop();

    final song = List.generate(60, (i) => cases[i * cases.length ~/ 60].first);
    final parseTimes = <int>[];
    final songTimes = <double>[];
    for (var sample = 0; sample < 7; sample++) {
      final (parseMicros, songMicros) = await Isolate.run(() async {
        MandarinReadings.initializeWorker(() async => tables);
        final loadTimer = Stopwatch()..start();
        final readings = await MandarinReadings.load();
        loadTimer.stop();

        final tokens = song.map(tokenize).toList();
        void readSong() {
          for (final line in tokens) {
            readings.forTokens(line);
          }
        }

        for (var i = 0; i < 20; i++) {
          readSong();
        }
        final lookupTimer = Stopwatch()..start();
        for (var i = 0; i < 100; i++) {
          readSong();
        }
        return (
          loadTimer.elapsedMicroseconds,
          lookupTimer.elapsedMicroseconds / 100,
        );
      });
      parseTimes.add(parseMicros);
      songTimes.add(songMicros);
    }
    stdout.writeln(
      'Mandarin table assets ${assetTimer.elapsedMicroseconds / 1000} ms, '
      'fresh-worker parse ${(parseTimes..sort())[3] / 1000} ms, '
      'warm lookup for 60 lines ${(songTimes..sort())[3] / 1000} ms',
    );
  }, skip: Platform.environment['MANDARIN_BENCHMARK'] != '1');

  test('Mandarin lyric reading benchmark preserves sentence and syllable accuracy', () async {
    final readings = await MandarinReadings.load();
    expect(cases.length, greaterThanOrEqualTo(400));
    expect(cases.map((row) => row.first).toSet(), hasLength(cases.length));

    var correctLines = 0, correctSyllables = 0, totalSyllables = 0;
    final differences = <String>[];
    for (final [text, pinyin] in cases) {
      final tokens = tokenize(text);
      final expected = pinyin.split(' ');
      expect(expected, hasLength(tokens.length), reason: 'Fixture: $text');
      final actual = readings.forTokens(tokens);
      var lineCorrect = true;
      for (final (index, syllable) in expected.indexed) {
        if (syllable != '-') {
          totalSyllables++;
          if (actual[index] == syllable) correctSyllables++;
        }
        if (actual[index] != (syllable == '-' ? null : syllable)) {
          lineCorrect = false;
        }
      }
      if (lineCorrect) {
        correctLines++;
      } else {
        differences.add(
          '$text\n  expected: $pinyin\n'
          '  actual:   ${List.generate(tokens.length, (i) => actual[i] ?? '-').join(' ')}',
        );
      }
    }
    stdout.writeln(
      'Mandarin sentences ${_percent(correctLines, cases.length)}, '
      'syllables ${_percent(correctSyllables, totalSyllables)}',
    );
    if (Platform.environment['MANDARIN_REPORT'] == '1') {
      stdout.writeln(differences.join('\n'));
    }
    final report = differences.join('\n');
    expect(
      correctLines / cases.length,
      greaterThanOrEqualTo(0.995),
      reason: report,
    );
    expect(
      correctSyllables / totalSyllables,
      greaterThanOrEqualTo(0.999),
      reason: report,
    );
  });

  test(
    'common lyric particles keep their readings across overlapping words',
    () async {
      final readings = await MandarinReadings.load();
      for (final (text, pinyin) in const [
        ('盲目的爱', 'mang mu de ai'),
        ('真的确定', 'zhen de que ding'),
        ('真心地爱你', 'zhen xin de ai ni'),
        ('用心地听', 'yong xin de ting'),
        ('失落地走', 'shi luo de zou'),
        ('我看到了你', 'wo kan dao le ni'),
        ('终于等到了', 'zhong yu deng dao le'),
        ('我们到了', 'wo men dao le'),
        ('穿着白衣', 'chuan zhe bai yi'),
        ('我找着你', 'wo zhao zhe ni'),
        ('点着头', 'dian zhe tou'),
        ('一会儿', 'yi hui er'),
        ('我得走了，还我自由', 'wo dei zou le huan wo zi you'),
      ]) {
        expect(
          readings.forTokens(tokenize(text)).values.join(' '),
          pinyin,
          reason: text,
        );
      }
    },
  );

  test(
    'known text ambiguities document the current default readings',
    () async {
      final readings = await MandarinReadings.load();
      for (final [text, pinyin, note] in _rows('mandarin_lyric_ambiguities')) {
        expect(
          readings.forTokens(tokenize(text)).values.join(' '),
          pinyin,
          reason: '$text：$note',
        );
      }
    },
  );
}
