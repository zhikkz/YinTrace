// Small app-wide helpers: keeping the screen on, the file picker's copies.
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/picked_files.dart';
import 'package:yintrace/src/app/screen_awake.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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
    late String? cachePath;
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    final messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    setUp(() {
      tmp = Directory.systemTemp.createTempSync('yt_picked');
      Directory('${tmp.path}/tmp').createSync();
      cachePath = '${tmp.path}/cache';
      Directory(cachePath!).createSync();
      messenger.setMockMethodCallHandler(channel, (call) async {
        expect(call.method, 'getTemporaryDirectory');
        return cachePath;
      });
    });
    tearDown(() {
      debugDefaultTargetPlatformOverride = null;
      messenger.setMockMethodCallHandler(channel, null);
      tmp.deleteSync(recursive: true);
    });

    File make(String path) => File('${tmp.path}/$path')
      ..createSync(recursive: true)
      ..writeAsStringSync('audio');

    Future<void> onPlatform(
      TargetPlatform platform,
      Future<void> Function() action, {
      Directory? systemTemporary,
    }) {
      debugDefaultTargetPlatformOverride = platform;
      return IOOverrides.runZoned(
        action,
        getSystemTempDirectory: () =>
            systemTemporary ?? Directory('${tmp.path}/tmp'),
      );
    }

    for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
      final base = platform == TargetPlatform.iOS ? 'tmp' : 'cache';
      final picker = platform == TargetPlatform.iOS
          ? 'flutter_file_picker'
          : 'file_picker';

      test(
        '${platform.name}: the picked copy is deleted, other picks stay',
        () => onPlatform(platform, () async {
          final song = make('$base/$picker/7C1E-A/song.flac');
          final other = make('$base/$picker/90B2-C/accompaniment.m4a');
          expect(await isPickedCopy(song.path), isTrue);
          await discardPickedCopy(song.path);
          expect(song.parent.existsSync(), isFalse);
          expect(
            other.readAsStringSync(),
            'audio',
            reason: 'a pick still waiting to be imported',
          );
          await discardPickedCopy(song.path); // already gone
          await discardPickedCopy(null);
          expect(other.existsSync(), isTrue);
        }),
      );

      test(
        '${platform.name}: user files and their siblings survive lookalike directories',
        () => onPlatform(platform, () async {
          for (final path in [
            'Documents/file_picker/123/lyrics.lrc',
            'Documents/flutter_file_picker/7C1E-A/song.flac',
            'Music/album/song.flac',
            'flutter_file_picker/song.flac',
          ]) {
            final own = make(path);
            final sibling = File('${own.parent.path}/keep.txt')
              ..writeAsStringSync('keep');
            final classified = await isPickedCopy(own.path);
            await discardPickedCopy(own.path);
            expect(own.readAsStringSync(), 'audio');
            expect(sibling.readAsStringSync(), 'keep');
            expect(classified, isFalse);
          }
        }),
      );

      test(
        '${platform.name}: only the selected file is removed from a shared pick',
        () => onPlatform(platform, () async {
          final song = make('$base/$picker/123/song.flac');
          final lyrics = make('$base/$picker/123/lyrics.lrc');
          await discardPickedCopy(song.path);
          await discardPickedCopy(
            song.path,
          ); // must not remove the remaining file
          expect(song.existsSync(), isFalse);
          expect(lyrics.readAsStringSync(), 'audio');
          await discardPickedCopy(lyrics.path);
          expect(lyrics.parent.existsSync(), isFalse);
          expect(
            lyrics.parent.parent.existsSync(),
            isTrue,
            reason: 'keep the picker root',
          );
          await discardPickedCopy(lyrics.path);
        }),
      );

      test(
        '${platform.name}: exact directory and file boundaries are required',
        () => onPlatform(platform, () async {
          final otherPicker = platform == TargetPlatform.iOS
              ? 'file_picker'
              : 'flutter_file_picker';
          for (final path in [
            '$base-backup/$picker/123/song.flac',
            '$base/nested/$picker/123/song.flac',
            '$base/$picker/song.flac',
            '$base/$picker/123/nested/song.flac',
            '$base/${picker}_backup/123/song.flac',
            '$base/$otherPicker/123/song.flac',
          ]) {
            final file = make(path);
            expect(await isPickedCopy(file.path), isFalse, reason: path);
            await discardPickedCopy(file.path);
            expect(file.readAsStringSync(), 'audio');
          }
          final kept = make('$base/$picker/123/kept.flac');
          final outside = make('Documents/file_picker/123/lyrics.lrc');
          for (final path in [
            '',
            '$picker/123/kept.flac', // relative
            '${tmp.path}/$base',
            kept.parent.parent.path, // picker root
            kept.parent.path, // pick directory, not a file
            '${kept.path}/',
            '${kept.parent.path}/./kept.flac',
            '${kept.parent.path}/nested/../kept.flac',
            '${tmp.path}/$base/$picker/../../Documents/file_picker/123/lyrics.lrc',
          ]) {
            expect(await isPickedCopy(path), isFalse, reason: path);
            await discardPickedCopy(path);
            expect(kept.readAsStringSync(), 'audio');
            expect(outside.readAsStringSync(), 'audio');
          }
        }),
      );

      for (final component in ['picker root', 'pick directory', 'file']) {
        test(
          '${platform.name}: a symlink at the $component cannot authorize deletion',
          () => onPlatform(platform, () async {
            final own = make('Documents/$picker/123/song.flac');
            final sibling = make('Documents/$picker/123/keep.txt');
            final root = Directory('${tmp.path}/$base/$picker');
            final picked = '${root.path}/123/song.flac';
            switch (component) {
              case 'picker root':
                Link(root.path).createSync(own.parent.parent.path);
              case 'pick directory':
                root.createSync();
                Link('${root.path}/123').createSync(own.parent.path);
              case 'file':
                Directory('${root.path}/123').createSync(recursive: true);
                Link(picked).createSync(own.path);
                // Even a link to another owned copy is not itself a copy.
                final cached = make('$base/$picker/123/cached.flac');
                final alias = Link('${root.path}/123/alias.flac')
                  ..createSync(cached.path);
                expect(await isPickedCopy(alias.path), isFalse);
                await discardPickedCopy(alias.path);
                expect(alias.existsSync(), isTrue);
                expect(cached.readAsStringSync(), 'audio');
            }
            expect(await isPickedCopy(picked), isFalse);
            await discardPickedCopy(picked);
            expect(own.readAsStringSync(), 'audio');
            expect(sibling.readAsStringSync(), 'audio');
          }),
          skip: Platform.isWindows
              ? 'Creating symlinks requires Windows privileges'
              : false,
        );
      }

      test(
        '${platform.name}: OS aliases of the trusted temporary directory work',
        () async {
          final song = make('$base/$picker/123/song.flac');
          final alias = Link('${tmp.path}/temp-alias')
            ..createSync('${tmp.path}/$base');
          cachePath = alias.path;
          await onPlatform(platform, () async {
            // The picker and the OS may use different spellings, e.g.
            // /var and /private/var on iOS.
            expect(await isPickedCopy(song.path), isTrue);
            await discardPickedCopy('${alias.path}/$picker/123/song.flac');
            expect(song.parent.existsSync(), isFalse);
            expect(alias.existsSync(), isTrue);
          }, systemTemporary: Directory(alias.path));
        },
        skip: Platform.isWindows
            ? 'Creating symlinks requires Windows privileges'
            : false,
      );
    }

    for (final platform in [
      TargetPlatform.macOS,
      TargetPlatform.linux,
      TargetPlatform.windows,
    ]) {
      test(
        '${platform.name}: directly picked originals are always left alone',
        () => onPlatform(platform, () async {
          for (final path in [
            'Documents/file_picker/123/lyrics.lrc',
            'tmp/flutter_file_picker/123/song.flac',
            'cache/file_picker/123/song.mp3',
          ]) {
            final own = make(path);
            final sibling = File('${own.parent.path}/keep.txt')
              ..writeAsStringSync('keep');
            expect(await isPickedCopy(own.path), isFalse);
            await discardPickedCopy(own.path);
            expect(own.readAsStringSync(), 'audio');
            expect(sibling.readAsStringSync(), 'keep');
          }
        }),
      );
    }

    test(
      'an unavailable Android cache directory never authorizes cleanup',
      () => onPlatform(TargetPlatform.android, () async {
        final song = make('cache/file_picker/123/song.flac');
        for (final unavailable in [null, '${tmp.path}/missing']) {
          cachePath = unavailable;
          expect(await isPickedCopy(song.path), isFalse);
          await discardPickedCopy(song.path);
          expect(song.readAsStringSync(), 'audio');
        }
        messenger.setMockMethodCallHandler(
          channel,
          (_) async => throw PlatformException(code: 'unavailable'),
        );
        expect(await isPickedCopy(song.path), isFalse);
        await discardPickedCopy(song.path);
        expect(song.readAsStringSync(), 'audio');
      }),
    );

    test(
      'an unavailable iOS temporary directory never authorizes cleanup',
      () async {
        final song = make('tmp/flutter_file_picker/123/song.flac');
        await onPlatform(TargetPlatform.iOS, () async {
          expect(await isPickedCopy(song.path), isFalse);
          await discardPickedCopy(song.path);
          expect(song.readAsStringSync(), 'audio');
        }, systemTemporary: Directory('${tmp.path}/missing'));
      },
    );
  });
}
