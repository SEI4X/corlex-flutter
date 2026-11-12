import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

/// What the SDK needs from an HTTP answer.
class HttpReply {
  const HttpReply(this.status, {this.retryAfter, this.etag, this.body = ''});

  final int status;
  final String? retryAfter;
  final String? etag;
  final String body;
}

/// The network, as one small seam: tests replace it, the app uses [IoHttp].
abstract class Http {
  /// Throws on a network failure (no answer at all).
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers);

  Future<HttpReply> get(Uri url, Map<String, String> headers);
}

/// Optional lifecycle seam; custom transports can implement their own cancellation.
abstract interface class ConsentAwareHttp {
  void pause();
  void resume();
}

void pauseHttp(Http http) {
  if (http is ConsentAwareHttp) (http as ConsentAwareHttp).pause();
}

void resumeHttp(Http http) {
  if (http is ConsentAwareHttp) (http as ConsentAwareHttp).resume();
}

/// `dart:io` client. The project key travels in `X-Corlex-Key`, never in the URL. Bodies over
/// 1 KiB are gzipped (ingest accepts `Content-Encoding: gzip`).
class IoHttp implements Http, ConsentAwareHttp {
  IoHttp({this.timeout = const Duration(seconds: 10)});

  final Duration timeout;
  final Set<HttpClient> _active = {};
  bool _paused = false;
  int _epoch = 0;

  @override
  void pause() {
    _paused = true;
    _epoch++;
    for (final client in _active.toList()) {
      client.close(force: true);
    }
  }

  @override
  void resume() {
    _paused = false;
  }

  static const int _gzipOver = 1024;
  static const int _maxResponseBytes = 1024 * 1024;

  @override
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers) =>
      _request(url, headers, body);

  @override
  Future<HttpReply> get(Uri url, Map<String, String> headers) =>
      _request(url, headers, null);

  Future<HttpReply> _request(
      Uri url, Map<String, String> headers, String? body) async {
    if (_paused) throw const HttpException('Corlex transport paused');
    final epoch = _epoch;
    final client = HttpClient()..connectionTimeout = timeout;
    _active.add(client);
    void current() {
      if (_paused || epoch != _epoch) {
        throw const HttpException('Corlex request cancelled');
      }
    }

    Future<HttpReply> perform() async {
      final request =
          body == null ? await client.getUrl(url) : await client.postUrl(url);
      current();
      request.followRedirects = false;
      headers.forEach(request.headers.set);
      if (body != null) {
        request.headers.contentType = ContentType.json;
        List<int> bytes = utf8.encode(body);
        if (bytes.length > _gzipOver) {
          request.headers.set(HttpHeaders.contentEncodingHeader, 'gzip');
          bytes = gzip.encode(bytes);
        }
        request.contentLength = bytes.length;
        request.add(bytes);
      }
      final reply = await _read(await request.close());
      current();
      return reply;
    }

    try {
      // One deadline covers connect, upload, headers and the decoded response stream together.
      return await perform().timeout(timeout);
    } finally {
      _active.remove(client);
      client.close(force: true);
    }
  }

  Future<HttpReply> _read(HttpClientResponse response) async {
    final bytes = BytesBuilder(copy: false);
    await for (final chunk in response) {
      if (chunk.length > _maxResponseBytes - bytes.length) {
        throw const HttpException('Corlex response exceeds 1 MiB');
      }
      bytes.add(chunk);
    }
    final body = utf8.decode(bytes.takeBytes());
    return HttpReply(
      response.statusCode,
      retryAfter: response.headers.value(HttpHeaders.retryAfterHeader),
      etag: response.headers.value(HttpHeaders.etagHeader),
      body: body,
    );
  }
}
