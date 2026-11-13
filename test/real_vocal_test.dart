// ignore_for_file: avoid_print
// Runs pitch analysis + per-character alignment on a real vocal recording.
// Skipped unless REAL_VOCAL (a WAV file) and REAL_LYRICS (an LRC file) are
// set. Writes reference.json / pitch.bin into REAL_OUT when given.
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/analysis/aligner.dart';
import 'package:yintrace/src/analysis/lrc.dart';
import 'package:yintrace/src/analysis/pitch_track.dart';
import 'package:yintrace/src/audio/audio_backend.dart';
import 'package:yintrace/src/library/song_repository.dart';

void main() {
  final wav = Platform.environment['REAL_VOCAL'];
  final lrcPath = Platform.environment['REAL_LYRICS'];
  test('real vocal analysis', () {
    final audio = const WavAudioBackend().decode(wav!, sampleRate: 44100, channels: 1);
    final sw = Stopwatch()..start();
    final track = analyzePitch(audio.samples, 44100);
    final tPitch = sw.elapsedMilliseconds;
    final lrc = parseLrc(File(lrcPath!).readAsStringSync());
    final ref = buildReference(track, lrc.lines);
    final tAll = sw.elapsedMilliseconds;
    var voiced = 0;
    for (var i = 0; i < track.length; i++) {
      if (track.voiced(i)) voiced++;
    }
    print('duration ${audio.duration.toStringAsFixed(1)} s, frames ${track.length}, '
        'voiced ${(100 * voiced / track.length).toStringAsFixed(1)}%, pitch ${tPitch}ms, total ${tAll}ms');
    for (final l in ref.lines) {
      final toks = l.tokens
          .map((t) => '${t.text}${t.start.toStringAsFixed(2)}${t.notes.isEmpty ? '∅' : ''}')
          .join(' ');
      print('[${formatLrcTime(l.lrcStart)}] ${l.start.toStringAsFixed(2)}-${l.end.toStringAsFixed(2)} $toks');
    }
    final out = Platform.environment['REAL_OUT'];
    if (out != null) {
      Directory(out).createSync(recursive: true);
      File('$out/reference.json').writeAsStringSync(jsonEncode(ref.toJson()));
      File('$out/pitch.bin').writeAsBytesSync(encodePitchTrack(track));
    }
  }, skip: wav == null || lrcPath == null, timeout: const Timeout(Duration(minutes: 5)));
}
