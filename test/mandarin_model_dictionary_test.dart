import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/hubertfa_lexicon.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/lyrics_language.dart';
import 'package:yintrace/src/analysis/mandarin_readings.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final modelDir = Platform.environment['HUBERTFA_MODEL_DIR'];

  test(
    'Mandarin syllables and fallbacks match the HuBERTFA v0.0.7 dictionary',
    () async {
      final modelPath = '$modelDir/model.onnx';
      expect(
        File(modelPath).existsSync(),
        isTrue,
        reason: 'Point HUBERTFA_MODEL_DIR to the extracted v0.0.7 directory.',
      );
      final line = parseLrc('[00:00]一会儿 嗯 哼 呒 噷 呣 㕶 绿略女虐').lines.single;
      final lexicon = await HubertFaLexicon.load(modelPath, [line]);
      final modelSyllables = lexicon.mandarinSyllables.toSet();
      final readings = await MandarinReadings.load();
      final unsupported = readings.syllables.difference(modelSyllables);

      stdout.writeln(
        'Mandarin syllables outside the model: ${(unsupported.toList()..sort()).join(', ')}',
      );
      expect(unsupported, {'hm', 'hng', 'm', 'n', 'ng'});
      expect(modelSyllables, containsAll(['er', 'lv', 'lve', 'nv', 'nve']));
      expect(modelSyllables, isNot(contains('r')));

      final automatic = readings.forTokens(line.tokens);
      expect(
        automatic[2],
        'er',
      ); // 儿 is its own aligned token and editor field.
      expect(automatic[3], 'ng');
      expect(automatic[5], 'm');

      final phones = lexicon.phones(line, LyricsLanguage.chinese, {});
      final withFallbacks = lexicon.phones(line, LyricsLanguage.chinese, {
        2: 'er',
        3: 'en',
        4: 'heng',
        5: 'fu',
        9: 'lǜ',
        10: 'lüè',
        11: 'nǚ',
        12: 'nüè',
      });
      expect(phones, withFallbacks);
      expect(phones.take(6).expand((p) => p), isNot(contains(unknownPhone)));
      expect(phones.sublist(6, 9), List.filled(3, [unknownPhone]));
      expect(phones.skip(9).expand((p) => p), isNot(contains(unknownPhone)));
      expect(
        lexicon.phones(line, LyricsLanguage.chinese, {
          2: 'r',
          3: 'ng',
          4: 'hng',
        }),
        phones,
      );
    },
    skip: modelDir == null
        ? 'Set HUBERTFA_MODEL_DIR to the extracted v0.0.7 model.'
        : false,
  );
}
