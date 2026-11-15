// Small app-wide helpers: keeping the screen on, the file picker's copies.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/picked_files.dart';
import 'package:yintrace/src/app/screen_awake.dart';

void main() {
  group('ScreenAwake', () {
    final calls = <bool>[];
    setUp(() {
      calls.clear();
      ScreenAwake.platform = (on) async => calls.add(on);
    });

    test('the screen stays on until the last holder lets go', () {
      final practice = ScreenAwake(), download = ScreenAwake();
      download.hold();
      practice.hold();
      expect(calls, [true]);
      // The download ends while the practice goes on.
      download.release();
      expect(calls, [true], reason: 'the practice still holds it');
      expect(practice.isHeld, isTrue);
      practice.release();
      expect(calls, [true, false]);
    });

    test('holding or releasing twice counts once', () {
      final a = ScreenAwake(), b = ScreenAwake();
      a
        ..hold()
        ..hold();
      b.hold();
      a
        ..release()
        ..release();
      expect(calls, [true]);
      b.held = false;
      expect(calls, [true, false]);
      a.held = false;
      expect(calls, [true, false]);
    });

    test('a platform without the plugin is not an error', () async {
      ScreenAwake.platform = (on) async => throw UnsupportedError('no plugin');
      final a = ScreenAwake()..hold();
      a.release();
      await Future<void>.delayed(Duration.zero);
    });
  });

  group('picked files', () {
    late Directory tmp;
    setUp(() => tmp = Directory.systemTemp.createTempSync('yt_picked'));
    tearDown(() => tmp.deleteSync(recursive: true));

    File make(String path) => File('${tmp.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync('audio');

    test('the picker\'s copy is deleted with its folder, other copies stay', () async {
      final song = make('tmp/flutter_file_picker/7C1E-A/song.flac');
      final other = make('tmp/flutter_file_picker/90B2-C/accompaniment.m4a');
      final android = make('cache/file_picker/1731658/song.mp3');
      expect(isPickedCopy(song.path), isTrue);
      expect(isPickedCopy(android.path), isTrue);
      await discardPickedCopy(song.path);
      expect(song.parent.existsSync(), isFalse);
      expect(other.existsSync(), isTrue, reason: 'a file still waiting to be imported');
      await discardPickedCopy(android.path);
      expect(android.parent.existsSync(), isFalse);
      await discardPickedCopy(song.path); // already gone
      await discardPickedCopy(null);
    });

    test('the user\'s own file is never deleted', () async {
      // On a desktop the picker returns the file itself.
      final own = make('Music/album/song.flac');
      final lookalike = make('flutter_file_picker/song.flac'); // not in a picker folder of its own
      for (final f in [own, lookalike]) {
        expect(isPickedCopy(f.path), isFalse);
        await discardPickedCopy(f.path);
        expect(f.existsSync(), isTrue);
      }
    });
  });
}
