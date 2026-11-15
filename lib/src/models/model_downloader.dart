import 'dart:async';
import 'dart:io';

class ModelDownloadException implements Exception {
  ModelDownloadException(this.message);
  final String message;
  @override
  String toString() => message;
}

/// The download could not be written to the device (no space left, most
/// likely). Another route would end the same way.
class ModelStorageException extends ModelDownloadException {
  ModelStorageException(super.message);
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
  ///
  /// With [minBytesPerSecond], a transfer that stays slower than that over
  /// [slowWindow] gives up with [ModelDownloadException] (so that another
  /// route can be tried); the partial file is kept.
  Future<void> fetch(
    Uri url,
    File partFile, {
    required int expectedBytes,
    void Function(int received)? onProgress,
    int minBytesPerSecond = 0,
    Duration slowWindow = const Duration(seconds: 30),
  }) async {
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
      return fetch(
        url,
        partFile,
        expectedBytes: expectedBytes,
        onProgress: onProgress,
        minBytesPerSecond: minBytesPerSecond,
        slowWindow: slowWindow,
      );
    }
    if (response.statusCode == HttpStatus.ok) {
      have = 0; // The server ignored the range: write from the start.
    } else if (response.statusCode != HttpStatus.partialContent) {
      await response.drain<void>().catchError((_) {});
      throw ModelDownloadException('下载服务器返回了错误（${response.statusCode}）');
    }
    final RandomAccessFile sink;
    try {
      sink = partFile.openSync(mode: have == 0 ? FileMode.write : FileMode.append);
    } on FileSystemException catch (e) {
      // Nobody will read the body: let go of the connection.
      unawaited(response.listen(null).cancel().catchError((_) {}));
      throw ModelStorageException(_describe(e));
    }
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
    // Bytes received at the start of each check period, oldest first.
    final samples = <(Duration, int)>[];
    final clock = Stopwatch()..start();
    Timer? slow;
    if (minBytesPerSecond > 0) {
      final period = Duration(microseconds: slowWindow.inMicroseconds ~/ 6);
      slow = Timer.periodic(period, (_) {
        final now = clock.elapsed;
        samples.add((now, received));
        while (samples.length > 1 && now - samples[1].$1 >= slowWindow) {
          samples.removeAt(0);
        }
        final (then, bytes) = samples.first;
        final span = now - then;
        if (span < slowWindow) return;
        final rate = (received - bytes) / (span.inMicroseconds / 1e6);
        if (rate < minBytesPerSecond) {
          fail(ModelDownloadException('下载太慢（每秒 ${(rate / 1024).toStringAsFixed(0)} KB）'));
        }
      });
      samples.add((Duration.zero, received));
    }
    _body = response.listen(
      (chunk) {
        if (done.isCompleted) return; // already failed or cancelled
        try {
          sink.writeFromSync(chunk);
        } on FileSystemException catch (e) {
          // Thrown here it would escape the stream and the download would
          // end as "interrupted", sending the user to check their network.
          fail(ModelStorageException(_describe(e)));
          return;
        }
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
    FileSystemException? closeError;
    try {
      await done.future;
    } finally {
      idle?.cancel();
      slow?.cancel();
      await _body?.cancel();
      _body = null;
      _done = null;
      try {
        sink.closeSync();
      } on FileSystemException catch (e) {
        closeError = e;
      }
    }
    if (closeError != null) throw ModelStorageException(_describe(closeError));
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
      // Every redirect, including 308 (hf-mirror.com outside China), which
      // HttpClientResponse.isRedirect does not count on every SDK.
      if (response.statusCode >= 300 && response.statusCode < 400 && response.statusCode != HttpStatus.notModified) {
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
    if (e is FileSystemException) {
      // ENOSPC is 28 on iOS, macOS, Android and Linux.
      return e.osError?.errorCode == 28 ? '存储空间不足，模型存不下。请腾出一些空间后重试' : '写入文件失败，可能是存储空间不足';
    }
    return '下载失败：$e';
  }
}
