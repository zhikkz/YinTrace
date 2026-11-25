import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:yintrace/src/app/licenses.dart';
import 'package:yintrace/src/app/update_check.dart';
import 'package:yintrace/src/ui/about_page.dart' show checkedTime;

ReleaseVersion v(String text) => ReleaseVersion.tryParse(text)!;

Map<String, dynamic> releaseJson(String tag, {String? url, String name = ''}) => {
  'tag_name': tag,
  'html_url': url ?? '$appSourceUrl/releases/tag/$tag',
  'name': name,
  'published_at': '2026-12-01T08:00:00Z',
  'draft': false,
  'prerelease': false,
};

LatestRelease release(String tag) => LatestRelease.fromJson(releaseJson(tag));

void main() {
  group('ReleaseVersion', () {
    test('reads tags and orders versions the way semantic versioning does', () {
      expect(v('v1.2.3').toString(), '1.2.3');
      expect(v('1.2.3+7').toString(), '1.2.3');
      expect(v(' V2.0 ').toString(), '2.0');
      for (final bad in ['', 'latest', 'v', '1..2', 'v1.2.x', '1.2.3.4.5', '99999999999.0']) {
        expect(ReleaseVersion.tryParse(bad), isNull, reason: bad);
      }
      final ordered = ['0.9.9', '1.0.0-alpha', '1.0.0-alpha.1', '1.0.0-alpha.beta', '1.0.0-beta.2', '1.0.0-beta.11',
          '1.0.0-rc.1', '1.0.0', '1.0.1', '1.1', '1.10.0', '2.0.0'];
      for (var i = 0; i + 1 < ordered.length; i++) {
        expect(v(ordered[i + 1]) > v(ordered[i]), isTrue, reason: '${ordered[i + 1]} > ${ordered[i]}');
        expect(v(ordered[i]) > v(ordered[i + 1]), isFalse);
      }
      expect(v('1.0').compareTo(v('1.0.0')), 0);
      expect(v('v1.0.0') > v(appVersion), isFalse);
    });
  });

  group('LatestRelease', () {
    test('opens only pages of this repository', () {
      expect(release('v1.1.0').url, '$appSourceUrl/releases/tag/v1.1.0');
      expect(LatestRelease.fromJson(releaseJson('v1.1.0', url: 'https://example.com/fake')).url, releasesPage);
      expect(LatestRelease.fromJson(releaseJson('v1.1.0', url: 'https://github.com/zhikkz/YinTraceX/x')).url,
          releasesPage);
      expect(() => LatestRelease.fromJson(releaseJson('nightly')), throwsFormatException);
      final restored = LatestRelease.fromJson(release('v1.1.0').toJson());
      expect(restored.version.toString(), '1.1.0');
      expect(restored.publishedAt, DateTime.utc(2026, 12, 1, 8));
    });
  });

  group('fetchLatestRelease', () {
    late HttpServer server;
    late Uri api;
    late Future<void> Function(HttpRequest) respond;
    final seen = <HttpRequest>[];

    setUp(() async {
      seen.clear();
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      api = Uri.parse('http://${server.address.host}:${server.port}/repos/zhikkz/YinTrace/releases/latest');
      server.listen((request) async {
        seen.add(request);
        await respond(request);
      });
    });

    tearDown(() => server.close(force: true));

    Future<void> answer(HttpRequest request, int status, String body) async {
      request.response
        ..statusCode = status
        ..headers.contentType = ContentType.json
        ..write(body);
      await request.response.close();
    }

    test('reads the latest release, and says who asks', () async {
      respond = (r) => answer(r, 200, jsonEncode(releaseJson('v1.4.0', name: '音迹 1.4')));
      final latest = await fetchLatestRelease(api: api);
      expect(latest!.tag, 'v1.4.0');
      expect(latest.name, '音迹 1.4');
      expect(seen.single.headers.value(HttpHeaders.userAgentHeader), 'YinTrace/$appVersion');
      expect(seen.single.headers.value(HttpHeaders.acceptHeader), 'application/vnd.github+json');
      // Nothing about the device or the songs goes along.
      expect(seen.single.uri.query, isEmpty);
    });

    test('no release yet is not an error', () async {
      respond = (r) => answer(r, 404, '{"message":"Not Found"}');
      expect(await fetchLatestRelease(api: api), isNull);
    });

    test('failures say what went wrong in words', () async {
      Future<String> message() =>
          fetchLatestRelease(api: api, timeout: const Duration(milliseconds: 300)).then<String>(
            (_) => 'no error',
            onError: (Object e) => (e as UpdateCheckException).message,
          );
      respond = (r) => answer(r, 403, '{"message":"API rate limit exceeded"}');
      expect(await message(), 'GitHub 暂时不接受查询，过一会儿再试');
      respond = (r) => answer(r, 500, '');
      expect(await message(), 'GitHub 返回了错误（500）');
      respond = (r) => answer(r, 200, '<html>');
      expect(await message(), '没能读懂 GitHub 返回的版本信息');
      respond = (r) => answer(r, 200, jsonEncode(releaseJson('nightly')));
      expect(await message(), '没能读懂 GitHub 返回的版本信息');
      final hang = Completer<void>();
      respond = (_) => hang.future;
      expect(await message(), '连接 GitHub 超时');
      hang.complete();
      await server.close(force: true);
      expect(await message(), '连不上 GitHub');
    });
  });

  group('UpdateChecker', () {
    late Directory tmp;
    late DateTime now;
    late List<FutureOr<LatestRelease?> Function()> answers;
    var fetches = 0;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('yt_updates');
      now = DateTime.utc(2026, 12, 2, 10);
      answers = [];
      fetches = 0;
    });

    tearDown(() => tmp.deleteSync(recursive: true));

    Future<LatestRelease?> fetch() async {
      fetches++;
      return answers.removeAt(0)();
    }

    File stateFile() => File('${tmp.path}/update_check.json');

    UpdateChecker checker({String current = '1.0.0'}) =>
        UpdateChecker(stateFile: stateFile(), fetch: fetch, currentVersion: current, now: () => now);

    test('a newer release is news until the About page shows it, and stays known after a restart', () async {
      final updates = checker();
      var notified = 0;
      updates.addListener(() => notified++);
      answers.add(() => release('v1.1.0'));
      await updates.check();
      expect(updates.status, UpdateCheckStatus.done);
      expect(updates.updateAvailable, isTrue);
      expect(updates.hasUnseenUpdate, isTrue);
      expect(updates.checkedAt, now);
      expect(notified, 2); // checking, then done
      await updates.markSeen();
      expect(updates.hasUnseenUpdate, isFalse);
      expect(updates.updateAvailable, isTrue);

      // The next start: no request needed to know about 1.1.0, already seen.
      final restarted = await UpdateChecker.load(stateFile(), fetch: fetch);
      expect(restarted.latest!.tag, 'v1.1.0');
      expect(restarted.updateAvailable, isTrue);
      expect(restarted.hasUnseenUpdate, isFalse);
      expect(fetches, 1);

      // An even newer one is news again.
      answers.add(() => release('v1.2.0'));
      await updates.check();
      expect(updates.hasUnseenUpdate, isTrue);
    });

    test('the same or an older release, or none at all, is no news', () async {
      final updates = checker(current: '1.1.0');
      for (final latest in [release('v1.1.0'), release('v1.0.9'), null]) {
        answers.add(() => latest);
        await updates.check();
        expect(updates.status, UpdateCheckStatus.done);
        expect(updates.updateAvailable, isFalse);
        expect(updates.hasUnseenUpdate, isFalse);
      }
      // After updating the app, the release found before is no longer news.
      answers.add(() => release('v1.1.0'));
      await checker().check();
      expect((await UpdateChecker.load(stateFile(), fetch: fetch)).updateAvailable, isTrue);
      final updated = UpdateChecker(stateFile: stateFile(), fetch: fetch, currentVersion: '1.1.0');
      expect(updated.updateAvailable, isFalse);
    });

    test('a check asked for shows why it failed and keeps what was known', () async {
      final updates = checker();
      answers.add(() => release('v1.1.0'));
      await updates.check();
      answers.add(() => throw UpdateCheckException('连不上 GitHub'));
      await updates.check();
      expect(updates.status, UpdateCheckStatus.failed);
      expect(updates.error, '连不上 GitHub');
      expect(updates.latest!.tag, 'v1.1.0');
      expect(updates.hasUnseenUpdate, isTrue);
    });

    test('automatic checks: only when on, once a day, an hour after a failure, silently', () async {
      final updates = checker();
      await updates.checkAutomatically(enabled: false);
      expect(fetches, 0);
      answers.add(() => throw UpdateCheckException('连不上 GitHub'));
      await updates.checkAutomatically(enabled: true);
      expect(fetches, 1);
      // Nobody asked: no failure is shown.
      expect(updates.status, UpdateCheckStatus.idle);
      expect(updates.error, isNull);
      now = now.add(const Duration(minutes: 30));
      await updates.checkAutomatically(enabled: true);
      expect(fetches, 1);
      now = now.add(const Duration(minutes: 31));
      answers.add(() => release('v1.1.0'));
      await updates.checkAutomatically(enabled: true);
      expect(fetches, 2);
      expect(updates.hasUnseenUpdate, isTrue);
      now = now.add(const Duration(hours: 23));
      await updates.checkAutomatically(enabled: true);
      expect(fetches, 2);
      now = now.add(const Duration(hours: 1, minutes: 1));
      answers.add(() => release('v1.1.0'));
      await updates.checkAutomatically(enabled: true);
      expect(fetches, 3);
      // The time is kept across restarts.
      final restarted = UpdateChecker(stateFile: stateFile(), fetch: fetch, now: () => now);
      expect(restarted.checkedAt, isNull);
      final loaded = await UpdateChecker.load(stateFile(), fetch: fetch);
      expect(loaded.checkedAt, now);
    });

    test('one request at a time', () async {
      final updates = checker();
      final reply = Completer<LatestRelease?>();
      answers.add(() => reply.future);
      final first = updates.check();
      final second = updates.check();
      final third = updates.checkAutomatically(enabled: true);
      expect(updates.checking, isTrue);
      reply.complete(release('v1.1.0'));
      await Future.wait([first, second, third]);
      expect(fetches, 1);
      expect(updates.checking, isFalse);
    });

    test('a damaged state file is as if never checked', () async {
      stateFile().writeAsStringSync('{not json');
      final updates = await UpdateChecker.load(stateFile(), fetch: fetch);
      expect(updates.checkedAt, isNull);
      expect(updates.latest, isNull);
    });
  });

  test('check times read the way people say them', () {
    final now = DateTime(2026, 12, 2, 18, 30);
    expect(checkedTime(DateTime(2026, 12, 2, 9, 5), now: now), '今天 09:05 ');
    expect(checkedTime(DateTime(2026, 12, 1, 23, 59), now: now), '昨天 23:59 ');
    expect(checkedTime(DateTime(2026, 11, 20, 8), now: now), '11 月 20 日');
    expect(checkedTime(DateTime(2025, 11, 20, 8), now: now), '2025 年 11 月 20 日');
  });
}
