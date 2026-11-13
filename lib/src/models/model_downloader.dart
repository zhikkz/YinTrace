import 'dart:async';
import 'dart:io';

class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

class DownloadCancelled implements Exception {
  const DownloadCancelled();
}

/// Downloads a large file to disk, resuming a partial download when the
/// server supports range requests (GitHub release assets do).
class ResumableDownload {
  ResumableDownload({HttpClient? client, this.idleTimeout = const Duration(seconds: 30)})
      : _client = client ??
            (HttpClient()
              ..connectionTimeout = const Duration(seconds: 20)
              // Honour http_proxy / https_proxy where they are set (desktops).
              ..findProxy = HttpClient.findProxyFromEnvironment);

  final HttpClient _client;
  final Duration idleTimeout;
  bool _cancelled = false;
  HttpClientRequest? _request;
  StreamSubscription<List<int>>? _body;
  Completer<void>? _done;

  /// Stops the transfer; [fetch] throws [DownloadCancelled]. The partial
  /// file is kept so that a later call continues where this one stopped.
  void cancel() {
    _cancelled = true;
    _request?.abort();
    final done = _done;
    if (done != null && !done.isCompleted) done.completeError(const DownloadCancelled());
  }

  void close() => _client.close(force: true);

  /// Downloads [url] into [partFile] (appending to what is already there).
  /// [onProgress] receives the number of bytes on disk.
  Future<void> fetch(Uri url, File partFile, {required int expectedBytes, void Function(int received)? onProgress}) async {
    _cancelled = false;
    var have = partFile.existsSync() ? partFile.lengthSync() : 0;
    if (have > expectedBytes) {
      partFile.deleteSync();
      have = 0;
    }
    if (have == expectedBytes) {
      onProgress?.call(have);
      return;
    }
    HttpClientResponse response;
    try {
      response = await _open(url, have);
    } on DownloadCancelled {
      rethrow;
    } on ModelDownloadException {
      rethrow;
    } catch (e) {
      if (_cancelled) throw const DownloadCancelled();
      throw ModelDownloadException(_describe(e));
    }
    if (response.statusCode == HttpStatus.requestedRangeNotSatisfiable) {
      // The partial file does not fit the server's file: start over.
      await response.drain<void>();
      if (partFile.existsSync()) partFile.deleteSync();
      return fetch(url, partFile, expectedBytes: expectedBytes, onProgress: onProgress);
    }
    if (response.statusCode == HttpStatus.ok) {
      have = 0; // The server ignored the range: write from the start.
    } else if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw ModelDownloadException('下载服务器返回了错误（${response.statusCode}）');
    }
    final sink = partFile.openSync(mode: have == 0 ? FileMode.write : FileMode.append);
    final done = Completer<void>();
    _done = done;
    var received = have;
    Timer? idle;
    void fail(Object error) {
      if (!done.isCompleted) done.completeError(error);
    }

    void arm() {
      idle?.cancel();
      idle = Timer(idleTimeout, () => fail(ModelDownloadException('网络太慢或已断开，下载停住了')));
    }

    arm();
    _body = response.listen(
      (chunk) {
        sink.writeFromSync(chunk);
        received += chunk.length;
        onProgress?.call(received);
        arm();
      },
      onError: (Object e) => fail(_cancelled ? const DownloadCancelled() : ModelDownloadException(_describe(e))),
      onDone: () {
        if (!done.isCompleted) done.complete();
      },
      cancelOnError: true,
    );
    try {
      await done.future;
    } finally {
      idle?.cancel();
      await _body?.cancel();
      _body = null;
      _done = null;
      sink.closeSync();
    }
    if (received != expectedBytes) {
      if (received > expectedBytes) partFile.deleteSync();
      throw ModelDownloadException('下载中断了（收到 $received / $expectedBytes 字节）');
    }
  }

  /// Sends the request, following redirects by hand so that the Range header
  /// reaches the final host.
  Future<HttpClientResponse> _open(Uri url, int from) async {
    var current = url;
    for (var hop = 0; hop < 6; hop++) {
      if (_cancelled) throw const DownloadCancelled();
      final request = await _client.getUrl(current);
      _request = request;
      request.followRedirects = false;
      request.headers.set(HttpHeaders.acceptEncodingHeader, 'identity');
      if (from > 0) request.headers.set(HttpHeaders.rangeHeader, 'bytes=$from-');
      final response = await request.close().timeout(idleTimeout);
      if (response.isRedirect) {
        final location = response.headers.value(HttpHeaders.locationHeader);
        await response.drain<void>();
        if (location == null) throw ModelDownloadException('下载地址无效');
        current = current.resolve(location);
        continue;
      }
      return response;
    }
    throw ModelDownloadException('下载地址重定向次数太多');
  }

  static String _describe(Object e) {
    if (e is SocketException || e is HandshakeException || e is HttpException) {
      return '连不上下载服务器，请检查网络';
    }
    if (e is TimeoutException) return '连接下载服务器超时';
    if (e is FileSystemException) return '写入文件失败，可能是存储空间不足';
    return '下载失败：$e';
  }
}
