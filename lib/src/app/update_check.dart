import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart' show AppLifecycleListener;

import 'atomic_file.dart';
import 'licenses.dart' show appSourceUrl, appVersion;

/// The newest published release, as GitHub reports it (drafts and
/// pre-releases are never "latest"). Publishing a release tagged vX.Y.Z is
/// what tells installed apps about version X.Y.Z (see docs/development.md).
const latestReleaseApi = 'https://api.github.com/repos/zhikkz/YinTrace/releases/latest';

/// The page that lists the releases, for when a release has no page of its own.
const releasesPage = '$appSourceUrl/releases';

/// A version such as 1.2.0 or 1.2.0-beta.1, as in a tag "v1.2.0". Build
/// metadata ("+5") does not count.
@immutable
class ReleaseVersion implements Comparable<ReleaseVersion> {
  const ReleaseVersion._(this.numbers, this.preRelease);

  final List<int> numbers;

  /// Empty for a release; "beta.1" for 1.2.0-beta.1, which comes before 1.2.0.
  final String preRelease;

  static final _pattern = RegExp(r'^[vV]?(\d{1,9}(?:\.\d{1,9}){0,3})(?:-([0-9A-Za-z.-]+))?(?:\+[0-9A-Za-z.-]+)?$');

  static ReleaseVersion? tryParse(String text) {
    final m = _pattern.firstMatch(text.trim());
    if (m == null) return null;
    return ReleaseVersion._([for (final part in m[1]!.split('.')) int.parse(part)], m[2] ?? '');
  }

  @override
  int compareTo(ReleaseVersion other) {
    for (var i = 0; i < math.max(numbers.length, other.numbers.length); i++) {
      final a = i < numbers.length ? numbers[i] : 0;
      final b = i < other.numbers.length ? other.numbers[i] : 0;
      if (a != b) return a.compareTo(b);
    }
    if (preRelease == other.preRelease) return 0;
    if (preRelease.isEmpty) return 1;
    if (other.preRelease.isEmpty) return -1;
    // Semantic versioning: dot-separated, numbers below words.
    final mine = preRelease.split('.'), theirs = other.preRelease.split('.');
    for (var i = 0; i < math.min(mine.length, theirs.length); i++) {
      final a = int.tryParse(mine[i]), b = int.tryParse(theirs[i]);
      final c = a != null && b != null
          ? a.compareTo(b)
          : a != null
          ? -1
          : b != null
          ? 1
          : mine[i].compareTo(theirs[i]);
      if (c != 0) return c;
    }
    return mine.length.compareTo(theirs.length);
  }

  bool operator >(ReleaseVersion other) => compareTo(other) > 0;

  @override
  String toString() => numbers.join('.') + (preRelease.isEmpty ? '' : '-$preRelease');
}

/// A published release.
@immutable
class LatestRelease {
  const LatestRelease({required this.tag, required this.version, required this.url, this.name = '', this.publishedAt});

  final String tag;
  final ReleaseVersion version;

  /// The release's page on GitHub, with its downloads.
  final String url;
  final String name;
  final DateTime? publishedAt;

  /// Reads GitHub's release JSON. Throws [FormatException] when the tag is
  /// not a version.
  factory LatestRelease.fromJson(Map<String, dynamic> json) {
    final tag = json['tag_name'];
    final version = tag is String ? ReleaseVersion.tryParse(tag) : null;
    if (tag is! String || version == null) throw FormatException('not a version tag: $tag');
    final page = json['html_url'];
    final name = json['name'];
    final published = json['published_at'];
    return LatestRelease(
      tag: tag,
      version: version,
      // Only pages of this repository are opened.
      url: page is String && page.startsWith('$appSourceUrl/') ? page : releasesPage,
      name: name is String ? name.trim() : '',
      publishedAt: published is String ? DateTime.tryParse(published) : null,
    );
  }

  Map<String, dynamic> toJson() => {
    'tag_name': tag,
    'html_url': url,
    'name': name,
    if (publishedAt != null) 'published_at': publishedAt!.toUtc().toIso8601String(),
  };
}

class UpdateCheckException implements Exception {
  UpdateCheckException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// Asks GitHub for the latest release; null when none has been published.
typedef ReleaseFetcher = Future<LatestRelease?> Function();

/// [ReleaseFetcher] over HTTPS. Sends only the request itself, with the
/// app's name and version as the user agent (GitHub requires one).
Future<LatestRelease?> fetchLatestRelease({Uri? api, Duration timeout = const Duration(seconds: 15)}) async {
  final client = HttpClient()
    ..connectionTimeout = const Duration(seconds: 10)
    // Honour http_proxy / https_proxy where they are set (desktops).
    ..findProxy = HttpClient.findProxyFromEnvironment
    ..userAgent = 'YinTrace/$appVersion';
  try {
    final request = await client.getUrl(api ?? Uri.parse(latestReleaseApi)).timeout(timeout);
    request.headers
      ..set(HttpHeaders.acceptHeader, 'application/vnd.github+json')
      ..set('X-GitHub-Api-Version', '2022-11-28');
    final response = await request.close().timeout(timeout);
    final body = await response.transform(utf8.decoder).join().timeout(timeout);
    switch (response.statusCode) {
      case HttpStatus.ok:
        final json = jsonDecode(body);
        if (json is! Map<String, dynamic>) throw const FormatException('not a release');
        return LatestRelease.fromJson(json);
      case HttpStatus.notFound:
        return null;
      case HttpStatus.forbidden || HttpStatus.tooManyRequests:
        throw UpdateCheckException('GitHub 暂时不接受查询，过一会儿再试');
      default:
        throw UpdateCheckException('GitHub 返回了错误（${response.statusCode}）');
    }
  } on TimeoutException {
    throw UpdateCheckException('连接 GitHub 超时');
  } on IOException {
    // SocketException, HandshakeException, HttpException: no route there.
    throw UpdateCheckException('连不上 GitHub');
  } on FormatException {
    throw UpdateCheckException('没能读懂 GitHub 返回的版本信息');
  } finally {
    client.close(force: true);
  }
}

enum UpdateCheckStatus { idle, checking, done, failed }

/// Whether a newer version than this one has been published. Checks when
/// asked, and on its own at most once a day while [AppSettings.autoCheckUpdates]
/// is on. A newer version is only ever shown as a red dot: never a dialog.
class UpdateChecker extends ChangeNotifier {
  UpdateChecker({
    File? stateFile,
    ReleaseFetcher? fetch,
    String currentVersion = appVersion,
    DateTime Function()? now,
  }) : _file = stateFile,
       _fetch = fetch ?? fetchLatestRelease,
       current = ReleaseVersion.tryParse(currentVersion)!,
       _now = now ?? DateTime.now;

  /// Restores what the last check found, so the red dot is there from the
  /// start without asking GitHub again.
  static Future<UpdateChecker> load(File stateFile, {ReleaseFetcher? fetch}) async {
    final checker = UpdateChecker(stateFile: stateFile, fetch: fetch);
    try {
      if (stateFile.existsSync()) checker._apply(jsonDecode(await stateFile.readAsString()) as Map<String, dynamic>);
    } catch (_) {
      // A damaged file: as if never checked.
    }
    return checker;
  }

  /// Automatic checks wait this long after a successful one, and an hour
  /// after one that failed.
  static const interval = Duration(hours: 24);
  static const retryAfter = Duration(hours: 1);

  final File? _file;
  final ReleaseFetcher _fetch;
  final DateTime Function() _now;
  final ReleaseVersion current;

  late final LatestStateWriter? _writer = switch (_file) {
    final file? => LatestStateWriter(file, () => jsonEncode(_toJson())),
    null => null,
  };

  UpdateCheckStatus _status = UpdateCheckStatus.idle;
  UpdateCheckStatus get status => _status;

  /// The latest release at the last successful check; null when none was
  /// published (or before the first check).
  LatestRelease? _latest;
  LatestRelease? get latest => _latest;

  /// When GitHub last answered.
  DateTime? _checkedAt;
  DateTime? get checkedAt => _checkedAt;

  DateTime? _attemptedAt;

  /// Why the last check asked for on the About page failed.
  String? _error;
  String? get error => _error;

  /// The tag of the release whose news the singer has already seen.
  String? _seenTag;

  Future<void>? _running;

  bool get checking => _status == UpdateCheckStatus.checking;

  /// A newer version is out.
  bool get updateAvailable => _latest != null && _latest!.version > current;

  /// The red dot on the way to the About page: a newer version the singer
  /// has not looked at there yet.
  bool get hasUnseenUpdate => updateAvailable && _latest!.tag != _seenTag;

  /// The About page was opened: the news is no longer new. Completes when
  /// that is saved.
  Future<void> markSeen() {
    if (!hasUnseenUpdate) return Future.value();
    _seenTag = _latest!.tag;
    notifyListeners();
    return _save();
  }

  /// Asks GitHub now (the About page's button). The result, or why it
  /// failed, is shown on that page.
  Future<void> check() => _check(automatic: false);

  /// Asks GitHub when [enabled] and it is time to (see [interval]). Fails
  /// silently: the next automatic check tries again.
  Future<void> checkAutomatically({required bool enabled}) {
    if (!enabled || _running != null) return _running ?? Future.value();
    final now = _now();
    final checked = _checkedAt, attempted = _attemptedAt;
    if (checked != null && now.difference(checked) < interval) return Future.value();
    if (attempted != null && now.difference(attempted) < retryAfter) return Future.value();
    return _check(automatic: true);
  }

  AppLifecycleListener? _lifecycle;

  /// Checks now if it is time, and each time the app comes back to the
  /// foreground. [enabled] is read each time.
  void startAutomaticChecks(bool Function() enabled) {
    _lifecycle ??= AppLifecycleListener(onResume: () => unawaited(checkAutomatically(enabled: enabled())));
    unawaited(checkAutomatically(enabled: enabled()));
  }

  Future<void> _check({required bool automatic}) => _running ??= _run(automatic).whenComplete(() => _running = null);

  Future<void> _run(bool automatic) async {
    final shown = !automatic || _status != UpdateCheckStatus.idle;
    if (shown) {
      _status = UpdateCheckStatus.checking;
      _error = null;
      notifyListeners();
    }
    _attemptedAt = _now();
    try {
      final release = await _fetch();
      _latest = release;
      _checkedAt = _now();
      _status = UpdateCheckStatus.done;
    } on UpdateCheckException catch (e) {
      if (shown) {
        _status = UpdateCheckStatus.failed;
        _error = e.message;
      }
    } catch (e) {
      if (shown) {
        _status = UpdateCheckStatus.failed;
        _error = '$e';
      }
    }
    notifyListeners();
    await _save();
  }

  void _apply(Map<String, dynamic> json) {
    _checkedAt = DateTime.tryParse(json['checkedAt'] as String? ?? '');
    _attemptedAt = DateTime.tryParse(json['attemptedAt'] as String? ?? '');
    _seenTag = json['seenTag'] as String?;
    final latest = json['latest'];
    if (latest is Map<String, dynamic>) {
      try {
        _latest = LatestRelease.fromJson(latest);
      } on FormatException {
        _latest = null;
      }
    }
  }

  Map<String, dynamic> _toJson() => {
    if (_checkedAt != null) 'checkedAt': _checkedAt!.toUtc().toIso8601String(),
    if (_attemptedAt != null) 'attemptedAt': _attemptedAt!.toUtc().toIso8601String(),
    if (_latest != null) 'latest': _latest!.toJson(),
    if (_seenTag != null) 'seenTag': _seenTag,
  };

  Future<void> _save() async {
    try {
      await _writer?.save();
    } on FileSystemException {
      // Only costs an extra check next time.
    }
  }

  @override
  void dispose() {
    _lifecycle?.dispose();
    super.dispose();
  }
}
