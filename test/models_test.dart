// Tests for getting the two separation models onto the device: the
// resumable download, the SHA-256 check and the byte-copy recipe that turns
// the downloaded PyTorch weights into an ONNX model.
//
// Set MODELS_DIR to a folder holding the real `6_HP-Karaoke-UVR.pth` to also
// assemble the real model with the recipe bundled in assets/models,
// LIVE_MODEL_DOWNLOAD=1 to download both models exactly like the app does
// (194 MB), and LIVE_MIRROR_CHECK=1 to check that the main route
// (hf-mirror.com) serves the official files.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:crypto/crypto.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/licenses.dart';
import 'package:yintrace/src/models/model_catalog.dart';
import 'package:yintrace/src/models/model_downloader.dart';
import 'package:yintrace/src/models/model_manager.dart';
import 'package:yintrace/src/models/model_recipe.dart';

Uint8List pseudoRandom(int n, int seed) {
  final out = Uint8List(n);
  var x = seed;
  for (var i = 0; i < n; i++) {
    x = (x * 1103515245 + 12345) & 0x7fffffff;
    out[i] = x >> 16;
  }
  return out;
}

String hex(List<int> bytes) => sha256.convert(bytes).toString();

/// A recipe over a fake "weights" file: the output interleaves pieces of
/// graph with ranges of the source, out of order and overlapping.
(ModelRecipe, Uint8List source, Uint8List expected) fakeRecipe() {
  final source = pseudoRandom(300000, 7);
  final graph = pseudoRandom(5000, 11);
  final segments = [
    [1200, 250000, 40000],
    [0, 100, 25000],
    [3000, 0, 100],
    [800, 0, 0],
  ];
  final out = BytesBuilder();
  var pos = 0;
  for (final s in segments) {
    out.add(graph.sublist(pos, pos + s[0]));
    pos += s[0];
    out.add(source.sublist(s[1], s[1] + s[2]));
  }
  final expected = out.toBytes();
  final json = jsonEncode({
    'format': 'yintrace-model-recipe',
    'version': 1,
    'source': {'name': 'weights.pth', 'bytes': source.length, 'sha256': hex(source)},
    'output': {'name': 'model.onnx', 'bytes': expected.length, 'sha256': hex(expected)},
    'graph': {'bytes': graph.length, 'sha256': hex(graph)},
    'segments': segments,
  });
  return (ModelRecipe.parse(json, graph), source, expected);
}

/// Serves files with range support, like GitHub's release downloads:
/// `/dl/<name>` redirects to `/blob/<name>`.
class FakeModelHost {
  FakeModelHost(this.files);
  final Map<String, Uint8List> files;
  late HttpServer server;
  final requests = <String>[];

  /// Cut the connection after this many body bytes (once).
  int? breakAfter;
  bool ignoreRanges = false;

  /// Status of the `/dl/` redirect.
  int redirectStatus = HttpStatus.found;

  /// Redirect `/dl/` to this site instead of to `/blob/` here (hf-mirror.com
  /// answers 308 to huggingface.co where it takes the request for one from
  /// abroad), e.g. `http://localhost:1234`.
  String? redirectTo;

  /// Answer every request with this status.
  int? failWith;

  /// Send the body in 1 kB pieces this far apart.
  Duration? trickle;

  Future<void> start() async {
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen(_handle);
  }

  String url(String name) => 'http://127.0.0.1:${server.port}/dl/$name';

  Future<void> _handle(HttpRequest r) async {
    final name = r.uri.pathSegments.last;
    final range = r.headers.value(HttpHeaders.rangeHeader);
    requests.add('${r.uri.path} ${range ?? '-'}');
    if (failWith case final status?) {
      r.response.statusCode = status;
      await r.response.close();
      return;
    }
    if (r.uri.path.startsWith('/dl/')) {
      r.response.statusCode = redirectStatus;
      r.response.headers.set(HttpHeaders.locationHeader, '${redirectTo ?? ''}/blob/$name');
      await r.response.close();
      return;
    }
    final data = files[name];
    if (data == null) {
      r.response.statusCode = HttpStatus.notFound;
      await r.response.close();
      return;
    }
    var from = 0;
    if (range != null && !ignoreRanges) {
      from = int.parse(RegExp(r'bytes=(\d+)-').firstMatch(range)!.group(1)!);
      if (from >= data.length) {
        r.response.statusCode = HttpStatus.requestedRangeNotSatisfiable;
        await r.response.close();
        return;
      }
      r.response.statusCode = HttpStatus.partialContent;
      r.response.headers.set(HttpHeaders.contentRangeHeader, 'bytes $from-${data.length - 1}/${data.length}');
    }
    r.response.contentLength = data.length - from;
    final cut = breakAfter;
    if (cut != null && cut < data.length - from) {
      breakAfter = null;
      // Send the headers and part of the body, then drop the connection.
      final socket = await r.response.detachSocket();
      socket.add(data.sublist(from, from + cut));
      await socket.flush();
      socket.destroy();
      return;
    }
    if (trickle case final pause?) {
      try {
        for (var i = from; i < data.length; i += 1024) {
          r.response.add(data.sublist(i, i + 1024 < data.length ? i + 1024 : data.length));
          await r.response.flush();
          await Future<void>.delayed(pause);
        }
        await r.response.close();
      } catch (_) {
        // The client gave up.
      }
      return;
    }
    r.response.add(data.sublist(from));
    await r.response.close();
  }

  Future<void> stop() => server.close(force: true);
}

void main() {
  late Directory tmp;

  setUp(() {
    HttpOverrides.global = null;
    tmp = Directory.systemTemp.createTempSync('yt_models');
  });
  tearDown(() => tmp.deleteSync(recursive: true));

  group('model recipe', () {
    test('assembles the output by copying byte ranges and hashes it', () {
      final (recipe, source, expected) = fakeRecipe();
      File('${tmp.path}/weights.pth').writeAsBytesSync(source);
      final digest = recipe.assembleSync('${tmp.path}/weights.pth', '${tmp.path}/model.onnx');
      expect(File('${tmp.path}/model.onnx').readAsBytesSync(), expected);
      expect(digest, recipe.outputSha256);
      expect(sha256OfFileSync('${tmp.path}/model.onnx'), recipe.outputSha256);
    });

    test('rejects a graph that does not belong to the recipe', () {
      final (recipe, _, _) = fakeRecipe();
      final bad = Uint8List.fromList(recipe.graph)..[10] ^= 1;
      final json = jsonEncode({
        'format': 'yintrace-model-recipe',
        'version': 1,
        'source': {'bytes': 1, 'sha256': ''},
        'output': {'bytes': 1, 'sha256': ''},
        'graph': {'bytes': recipe.graph.length, 'sha256': hex(recipe.graph)},
        'segments': <List<int>>[],
      });
      expect(() => ModelRecipe.parse(json, bad), throwsFormatException);
    });

    test('a truncated source is an error, not a short model', () {
      final (recipe, source, _) = fakeRecipe();
      File('${tmp.path}/weights.pth').writeAsBytesSync(source.sublist(0, 200000));
      expect(
        () => recipe.assembleSync('${tmp.path}/weights.pth', '${tmp.path}/model.onnx'),
        throwsA(isA<FileSystemException>()),
      );
    });

    test('the bundled recipe matches the catalog', () {
      final recipe = ModelRecipe.parse(
        File('assets/models/karaoke_graph.json').readAsStringSync(),
        File('assets/models/karaoke_graph.bin').readAsBytesSync(),
      );
      expect(recipe.sourceSha256, karaokeModel.sha256);
      expect(recipe.sourceBytes, karaokeModel.bytes);
      expect(recipe.outputBytes, karaokeModel.installedBytes);
      // Every byte of the ONNX file comes from the graph or from the .pth,
      // and every copied range lies inside the .pth.
      var total = 0, literal = 0;
      for (final s in recipe.segments) {
        literal += s[0];
        total += s[0] + s[2];
        expect(s[1] + s[2], lessThanOrEqualTo(recipe.sourceBytes));
      }
      expect(literal, recipe.graph.length);
      expect(total, recipe.outputBytes);
      // The bundle carries the graph only: no weights.
      expect(recipe.graph.length, lessThan(200 * 1024));
      expect(vocalModel.installedBytes, vocalModel.bytes);
      expect(vocalModel.needsAssembly, isTrue);
      expect(karaokeModel.needsAssembly, isTrue);
    });

    test('the MDX patch replaces only the two time dimensions', () {
      final recipe = ModelRecipe.parse(
        File('assets/models/mdx_graph.json').readAsStringSync(),
        File('assets/models/mdx_graph.bin').readAsBytesSync(),
      );
      expect(recipe.sourceBytes, vocalModel.bytes);
      expect(recipe.sourceSha256, vocalModel.sha256);
      expect(recipe.outputBytes, vocalModel.installedBytes);
      expect(recipe.outputSha256, '86532df82bb423e62e542e3e3856cba54b4235724177b4d21d77260b59cbd322');
      expect(recipe.graph, [0x12, 0x01, 0x54, 0x12, 0x01, 0x54]);
    });

    final real = Platform.environment['MODELS_DIR'];
    test(
      'assembles the real 6_HP-Karaoke-UVR model',
      () {
        final recipe = ModelRecipe.parse(
          File('assets/models/karaoke_graph.json').readAsStringSync(),
          File('assets/models/karaoke_graph.bin').readAsBytesSync(),
        );
        final pth = '$real/${karaokeModel.fileName}';
        expect(sha256OfFileSync(pth), karaokeModel.sha256);
        final out = '${tmp.path}/${karaokeModel.installedName}';
        expect(recipe.assembleSync(pth, out), recipe.outputSha256);
        expect(File(out).lengthSync(), karaokeModel.installedBytes);
        final keep = Platform.environment['MODELS_OUT'];
        if (keep != null) {
          File(out).copySync('$keep/${karaokeModel.installedName}');
        }
        final voc = File('$real/${vocalModel.fileName}');
        final mdxRecipe = ModelRecipe.parse(
          File('assets/models/mdx_graph.json').readAsStringSync(),
          File('assets/models/mdx_graph.bin').readAsBytesSync(),
        );
        final dynamic = '${tmp.path}/${vocalModel.installedName}';
        expect(mdxRecipe.assembleSync(voc.path, dynamic), mdxRecipe.outputSha256);
        if (keep != null) {
          File(dynamic).copySync('$keep/${vocalModel.installedName}');
        }
      },
      skip: real == null ? 'set MODELS_DIR to run' : false,
      timeout: const Timeout(Duration(minutes: 5)),
    );
  });

  group('resumable download', () {
    late FakeModelHost host;
    final payload = pseudoRandom(700000, 3);

    setUp(() async {
      host = FakeModelHost({'a.bin': payload});
      await host.start();
    });
    tearDown(() => host.stop());

    test('follows the redirect and reports progress', () async {
      final part = File('${tmp.path}/a.part');
      final seen = <int>[];
      final d = ResumableDownload();
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length, onProgress: seen.add);
      d.close();
      expect(part.readAsBytesSync(), payload);
      expect(seen.last, payload.length);
      expect(host.requests, ['/dl/a.bin -', '/blob/a.bin -']);
    });

    test('continues a broken download with a range request', () async {
      final part = File('${tmp.path}/a.part');
      host.breakAfter = 250000;
      final d = ResumableDownload();
      await expectLater(
        d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length),
        throwsA(isA<ModelDownloadException>()),
      );
      final have = part.lengthSync();
      expect(have, inInclusiveRange(1, payload.length - 1));
      host.requests.clear();
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length);
      d.close();
      expect(part.readAsBytesSync(), payload);
      expect(host.requests.last, '/blob/a.bin bytes=$have-');
    });

    test('follows a permanent (308) redirect', () async {
      host.redirectStatus = HttpStatus.permanentRedirect;
      final part = File('${tmp.path}/a.part');
      final d = ResumableDownload();
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length);
      d.close();
      expect(part.readAsBytesSync(), payload);
      expect(host.requests, ['/dl/a.bin -', '/blob/a.bin -']);
    });

    test('told to stay on the site, does not follow a permanent redirect to another one', () async {
      // The same server under another name: "localhost" is not "127.0.0.1".
      host.redirectTo = 'http://localhost:${host.server.port}';
      final part = File('${tmp.path}/a.part');
      final d = ResumableDownload();
      for (final status in [HttpStatus.movedPermanently, HttpStatus.permanentRedirect]) {
        host.redirectStatus = status;
        host.requests.clear();
        await expectLater(
          d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length, stayOnSite: true),
          throwsA(isA<ModelDownloadException>().having((e) => e.message, 'message', contains('转到了 localhost'))),
        );
        expect(host.requests, ['/dl/a.bin -'], reason: '$status');
        expect(part.existsSync(), isFalse);
      }
      // A temporary redirect to another site is how a download is handed to
      // a file server (GitHub does), and one within the site stays on it.
      host.redirectStatus = HttpStatus.found;
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length, stayOnSite: true);
      expect(part.readAsBytesSync(), payload);
      part.deleteSync();
      host
        ..redirectTo = null
        ..redirectStatus = HttpStatus.permanentRedirect;
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length, stayOnSite: true);
      expect(part.readAsBytesSync(), payload);
      d.close();
    });

    test('gives up on a transfer that stays too slow, keeping what arrived', () async {
      host.trickle = const Duration(milliseconds: 40); // about 25 kB/s
      final part = File('${tmp.path}/a.part');
      final d = ResumableDownload();
      await expectLater(
        d.fetch(
          Uri.parse(host.url('a.bin')),
          part,
          expectedBytes: payload.length,
          minBytesPerSecond: 200 * 1024,
          slowWindow: const Duration(milliseconds: 600),
        ),
        throwsA(isA<ModelDownloadException>().having((e) => e.message, 'message', startsWith('下载太慢'))),
      );
      d.close();
      expect(part.lengthSync(), inExclusiveRange(0, payload.length));
    });

    test('starts over when the server ignores the range', () async {
      final part = File('${tmp.path}/a.part')..writeAsBytesSync(pseudoRandom(1000, 99));
      host.ignoreRanges = true;
      final d = ResumableDownload();
      await d.fetch(Uri.parse(host.url('a.bin')), part, expectedBytes: payload.length);
      d.close();
      expect(part.readAsBytesSync(), payload);
    });

    test('a full disk is reported as that, not as a broken download', () async {
      // Every write to /dev/full fails with "no space left on device".
      final d = ResumableDownload();
      await expectLater(
        d.fetch(Uri.parse(host.url('a.bin')), File('/dev/full'), expectedBytes: payload.length),
        throwsA(isA<ModelStorageException>().having((e) => e.message, 'message', contains('存储空间不足'))),
      );
      d.close();
    }, skip: !File('/dev/full').existsSync());

    test('a missing file and an unreachable host give readable errors', () async {
      final d = ResumableDownload();
      await expectLater(
        d.fetch(Uri.parse(host.url('nope.bin')), File('${tmp.path}/n.part'), expectedBytes: 10),
        throwsA(isA<ModelDownloadException>().having((e) => e.message, 'message', contains('404'))),
      );
      final port = host.server.port;
      await host.stop();
      await expectLater(
        d.fetch(Uri.parse('http://127.0.0.1:$port/dl/a.bin'), File('${tmp.path}/n.part'), expectedBytes: 10),
        throwsA(isA<ModelDownloadException>().having((e) => e.message, 'message', contains('网络'))),
      );
      d.close();
    });
  });

  group('model manager', () {
    late FakeModelHost host;
    late FakeModelHost mirror;
    late ModelRecipe recipe;
    late Uint8List weights, onnx, plain;
    late List<ModelSpec> specs;

    setUp(() async {
      final (r, source, expected) = fakeRecipe();
      recipe = r;
      weights = source;
      onnx = expected;
      plain = pseudoRandom(180000, 5);
      host = FakeModelHost({'voc.onnx': plain, 'kara.pth': weights});
      await host.start();
      mirror = FakeModelHost({'voc.onnx': plain, 'kara.pth': weights});
      await mirror.start();
      specs = [
        ModelSpec(
          id: 'vocals',
          title: '人声分离',
          purpose: '',
          fileName: 'voc.onnx',
          url: host.url('voc.onnx'),
          bytes: plain.length,
          sha256: hex(plain),
          installedName: 'voc.onnx',
          installedBytes: plain.length,
        ),
        ModelSpec(
          id: 'karaoke',
          title: '去和声',
          purpose: '',
          fileName: 'kara.pth',
          url: host.url('kara.pth'),
          bytes: weights.length,
          sha256: hex(weights),
          installedName: 'kara.onnx',
          installedBytes: onnx.length,
        ),
      ];
    });
    tearDown(() async {
      await host.stop();
      await mirror.stop();
    });

    ModelManager manager({List<String>? excluded}) => ModelManager(
      dir: Directory('${tmp.path}/models'),
      loadRecipe: (_) async => recipe,
      specs: specs,
      excludeFromBackup: excluded?.add,
    );

    test('downloads, verifies, assembles and cleans up', () async {
      final excluded = <String>[];
      final m = manager(excluded: excluded);
      final phases = <ModelPhase>[];
      m.addListener(() => phases.add(m.phase));
      expect(m.isReady, isFalse);
      expect(m.pathFor(specs[0]), isNull);
      expect(m.totalBytes, plain.length + weights.length);
      await m.install();
      expect(m.error, isNull);
      expect(m.isReady, isTrue);
      expect(m.phase, ModelPhase.ready);
      expect(File(m.pathFor(specs[0])!).readAsBytesSync(), plain);
      expect(File(m.pathFor(specs[1])!).readAsBytesSync(), onnx);
      expect(phases, containsAll([ModelPhase.downloading, ModelPhase.verifying, ModelPhase.preparing]));
      expect(m.progress, 1);
      expect(excluded, ['${tmp.path}/models']);
      // Only the two models remain: no .part, no .pth, no .tmp.
      final names = Directory('${tmp.path}/models').listSync().map((f) => f.path.split('/').last).toSet();
      expect(names, {'voc.onnx', 'kara.onnx'});
      expect(m.installedBytes, plain.length + onnx.length);
      // A second manager (next app start) finds them without the network.
      await host.stop();
      expect(manager().isReady, isTrue);
    });

    test('migrates a previously downloaded official source without networking', () async {
      final m = manager();
      await m.dir.create(recursive: true);
      File('${m.dir.path}/${specs[1].fileName}').writeAsBytesSync(weights);
      await m.install();
      expect(m.error, isNull);
      expect(m.isReady, isTrue);
      expect(host.requests.where((r) => r.contains('kara.pth')), isEmpty);
      expect(File('${m.dir.path}/${specs[1].fileName}').existsSync(), isFalse);
    });

    test('a corrupt download is rejected and can be retried', () async {
      final good = host.files['kara.pth']!;
      host.files['kara.pth'] = Uint8List.fromList(good)..[1234] ^= 0xff;
      final m = manager();
      await m.install();
      expect(m.phase, ModelPhase.failed);
      expect(m.error, contains('校验失败'));
      expect(m.isInstalled(specs[0]), isTrue);
      expect(m.isInstalled(specs[1]), isFalse);
      expect(File('${tmp.path}/models/kara.pth.part').existsSync(), isFalse);
      host.files['kara.pth'] = good;
      host.requests.clear();
      await m.install();
      expect(m.isReady, isTrue);
      // The model that was already installed is not downloaded again.
      expect(host.requests.where((r) => r.contains('voc.onnx')), isEmpty);
    });

    test('an interrupted download resumes where it stopped', () async {
      host.breakAfter = 60000;
      final m = manager();
      await m.install();
      expect(m.phase, ModelPhase.failed);
      final have = File('${tmp.path}/models/voc.onnx.part').lengthSync();
      expect(have, greaterThan(0));
      host.requests.clear();
      await m.install();
      expect(m.isReady, isTrue);
      expect(host.requests, contains('/blob/voc.onnx bytes=$have-'));
    });

    test('models picked from Files are recognised by content', () async {
      await host.stop();
      File('${tmp.path}/renamed-download').writeAsBytesSync(weights);
      File('${tmp.path}/vocal model.onnx').writeAsBytesSync(plain);
      File('${tmp.path}/song.mp3').writeAsBytesSync(pseudoRandom(1000, 1));
      final m = manager();
      expect(await m.importFiles(['${tmp.path}/song.mp3']), 0);
      expect(m.error, contains('不是这两个模型'));
      final n = await m.importFiles([
        '${tmp.path}/renamed-download',
        '${tmp.path}/song.mp3',
        '${tmp.path}/vocal model.onnx',
      ]);
      expect(n, 2);
      expect(m.error, isNull);
      expect(m.isReady, isTrue);
      expect(File(m.pathFor(specs[1])!).readAsBytesSync(), onnx);
      // The user's own files are left alone.
      expect(File('${tmp.path}/renamed-download').existsSync(), isTrue);
      // A file of the right size but different content is refused.
      await m.deleteAll();
      expect(m.isReady, isFalse);
      File('${tmp.path}/fake').writeAsBytesSync(Uint8List.fromList(plain)..[5] ^= 1);
      expect(await m.importFiles(['${tmp.path}/fake']), 0);
      expect(m.error, contains('校验失败'));
    });

    group('backup route', () {
      List<ModelSpec> withMirror(List<ModelSpec> specs) => [
        for (final s in specs)
          ModelSpec(
            id: s.id,
            title: s.title,
            purpose: s.purpose,
            fileName: s.fileName,
            url: s.url,
            bytes: s.bytes,
            sha256: s.sha256,
            installedName: s.installedName,
            installedBytes: s.installedBytes,
            mirrors: [mirror.url(s.fileName)],
          ),
      ];

      setUp(() => specs = withMirror(specs));

      test('the main route cannot be reached: everything comes from the mirror', () async {
        final port = host.server.port;
        await host.stop();
        specs = [
          for (final s in specs)
            ModelSpec(
              id: s.id,
              title: s.title,
              purpose: s.purpose,
              fileName: s.fileName,
              url: 'http://127.0.0.1:$port/dl/${s.fileName}',
              bytes: s.bytes,
              sha256: s.sha256,
              installedName: s.installedName,
              installedBytes: s.installedBytes,
              mirrors: s.mirrors,
            ),
        ];
        final m = manager();
        final routes = <(String?, bool)>{};
        m.addListener(() {
          if (m.phase == ModelPhase.downloading) routes.add((m.route, m.onBackupRoute));
        });
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(File(m.pathFor(specs[1])!).readAsBytesSync(), onnx);
        expect(routes, contains(('127.0.0.1', true)));
        expect(m.route, isNull);
      });

      test('the main route hands the request to another site: the backup route is used instead', () async {
        // What hf-mirror.com does from abroad: 308 to huggingface.co.
        host
          ..redirectStatus = HttpStatus.permanentRedirect
          ..redirectTo = 'http://localhost:${host.server.port}';
        final m = manager();
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(host.requests, ['/dl/voc.onnx -'], reason: 'the redirect is not followed, and not asked for again');
        expect(mirror.requests.where((r) => r.startsWith('/blob/')), hasLength(2));
      });

      test('a backup route may hand the request on', () async {
        host.failWith = HttpStatus.serviceUnavailable;
        final other = FakeModelHost({'voc.onnx': plain, 'kara.pth': weights});
        await other.start();
        addTearDown(other.stop);
        mirror
          ..redirectStatus = HttpStatus.permanentRedirect
          ..redirectTo = 'http://localhost:${other.server.port}';
        final m = manager();
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(other.requests.where((r) => r.startsWith('/blob/')), hasLength(2));
      });

      test('a server error, then the second file goes straight to the route that worked', () async {
        host.failWith = HttpStatus.serviceUnavailable;
        final m = manager();
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(host.requests, ['/dl/voc.onnx -'], reason: 'the main route is not asked again for the second file');
        expect(mirror.requests.where((r) => r.startsWith('/blob/')), hasLength(2));
      });

      test('a file that does not match its SHA-256 is fetched again from the mirror', () async {
        host.files['kara.pth'] = Uint8List.fromList(weights)..[1234] ^= 0xff;
        final m = manager();
        await m.install();
        expect(m.error, isNull);
        expect(File(m.pathFor(specs[1])!).readAsBytesSync(), onnx);
        expect(mirror.requests, ['/dl/kara.pth -', '/blob/kara.pth -']);
      });

      test('a download that breaks half way continues on the mirror', () async {
        host.breakAfter = 60000;
        final m = manager();
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(mirror.requests.first, '/dl/voc.onnx bytes=60000-');
        expect(mirror.requests[1], '/blob/voc.onnx bytes=60000-');
      });

      test('test builds can download over the backup route only, once', () async {
        final m = manager()..backupOnly = true;
        final routes = <String?>{};
        m.addListener(() {
          if (m.phase == ModelPhase.downloading && m.onBackupRoute) routes.add(m.route);
        });
        await m.install();
        expect(m.error, isNull);
        expect(m.isReady, isTrue);
        expect(host.requests, isEmpty);
        expect(routes, {'127.0.0.1'});
        expect(m.backupOnly, isFalse);
      });

      test('a full disk does not send the user to the backup route or to their network', () async {
        final m = manager();
        await m.dir.create(recursive: true);
        Link('${m.dir.path}/voc.onnx.part').createSync('/dev/full');
        await m.install();
        expect(m.phase, ModelPhase.failed);
        expect(m.error, contains('存储空间不足'));
        expect(m.error, isNot(contains('网络')));
        expect(mirror.requests, isEmpty, reason: 'the other route would fail the same way');
      }, skip: !File('/dev/full').existsSync());

      test('failing on both routes names both', () async {
        host.failWith = HttpStatus.serviceUnavailable;
        mirror.failWith = HttpStatus.notFound;
        final m = manager();
        await m.install();
        expect(m.phase, ModelPhase.failed);
        // The user reads what to do; what each route answered is for testers.
        expect(m.error, '模型下载不了，请检查网络后重试');
        expect(m.errorDetail, startsWith('127.0.0.1：'));
        expect(m.errorDetail, contains('（503）'));
        expect(m.errorDetail, contains('（404）'));
        expect(m.isInstalled(specs[0]), isFalse);
        // One route's own message needs no detail.
        mirror.failWith = null;
        host.failWith = null;
        await m.install();
        expect(m.error, isNull);
        expect(m.errorDetail, isNull);
      });
    });

    test('deleting frees everything, including files from the fixed-window version', () async {
      final m = manager();
      await m.install();
      File('${m.dir.path}/UVR-MDX-NET-Voc_FT.onnx').writeAsStringSync('old model');
      File('${m.dir.path}/6_HP-Karaoke-UVR.onnx').writeAsStringSync('old model');
      await m.deleteAll();
      expect(m.isReady, isFalse);
      expect(m.phase, ModelPhase.missing);
      expect(Directory('${tmp.path}/models').listSync(), isEmpty);
    });
  });

  test(
    'downloads and installs the real models',
    () async {
      final m = ModelManager(
        dir: Directory('${tmp.path}/models'),
        loadRecipe: (spec) async {
          final name = spec.id == vocalModel.id ? 'mdx_graph' : 'karaoke_graph';
          return ModelRecipe.parse(
            File('assets/models/$name.json').readAsStringSync(),
            File('assets/models/$name.bin').readAsBytesSync(),
          );
        },
      );
      final watch = Stopwatch()..start();
      await m.install();
      expect(m.error, isNull);
      expect(m.isReady, isTrue);
      expect(
        sha256OfFileSync(m.pathFor(vocalModel)!),
        '86532df82bb423e62e542e3e3856cba54b4235724177b4d21d77260b59cbd322',
      );
      expect(
        sha256OfFileSync(m.pathFor(karaokeModel)!),
        '6247a65bd0e23c18d8f98df3ad5b40c0f8d4acc0da6949bf61847c3dad50c26e',
      );
      expect(Directory('${tmp.path}/models').listSync().length, 2);
      // ignore: avoid_print
      print('downloaded and installed ${formatMegabytes(m.totalBytes)} in ${watch.elapsed.inSeconds} s');
    },
    skip: Platform.environment['LIVE_MODEL_DOWNLOAD'] == null ? 'set LIVE_MODEL_DOWNLOAD=1 to run' : false,
    timeout: const Timeout(Duration(minutes: 20)),
  );

  test('the two models come from hf-mirror.com, with the UVR model repository as backup', () {
    for (final spec in separationModels) {
      expect(
        spec.url,
        'https://hf-mirror.com/Blane187/all_public_uvr_models/resolve/fddec39677560e41e3194f24a9e4c4cd32ef0e83/${spec.fileName}',
      );
      expect(spec.sha256.length, 64);
      expect(spec.mirrors, [
        'https://github.com/TRvlvr/model_repo/releases/download/all_public_uvr_models/${spec.fileName}',
      ]);
      expect(spec.sources.map(routeName), ['hf-mirror.com', 'github.com']);
    }
    expect(separationModels.map((s) => s.fileName), ['UVR-MDX-NET-Voc_FT.onnx', '6_HP-Karaoke-UVR.pth']);
    expect(formatMegabytes(separationModels.fold(0, (s, m) => s + m.bytes)), '194 MB');
  });

  test(
    'the main route serves the official files',
    () async {
      // Follow the redirects with HEAD requests: Hugging Face states the
      // file's SHA-256 and size in X-Linked-Etag / X-Linked-Size, so nothing
      // has to be downloaded.
      final client = HttpClient();
      addTearDown(client.close);
      for (final spec in separationModels) {
        var url = Uri.parse(spec.url);
        String? sha, size;
        for (var hop = 0; hop < 6 && sha == null; hop++) {
          final request = await client.headUrl(url);
          request.followRedirects = false;
          final response = await request.close();
          await response.drain<void>();
          sha = response.headers.value('x-linked-etag')?.replaceAll('"', '');
          size = response.headers.value('x-linked-size') ?? '${response.contentLength}';
          final location = response.headers.value(HttpHeaders.locationHeader);
          if (sha == null && location != null && response.statusCode >= 300 && response.statusCode < 400) {
            url = url.resolve(location);
          } else if (sha == null) {
            fail('${spec.fileName}: ${response.statusCode} without a SHA-256 from $url');
          }
        }
        expect(sha, spec.sha256, reason: spec.fileName);
        expect(size, '${spec.bytes}', reason: spec.fileName);
      }
    },
    skip: Platform.environment['LIVE_MIRROR_CHECK'] == null ? 'set LIVE_MIRROR_CHECK=1 to run' : false,
  );

  test('the version shown in the app is the one in pubspec.yaml', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: (\S+)\+', multiLine: true).firstMatch(pubspec)!.group(1), appVersion);
  });
}
