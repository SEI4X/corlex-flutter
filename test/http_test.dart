import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:corlex_flutter/src/http.dart';
import 'package:flutter_test/flutter_test.dart';

/// The real `dart:io` client against a real local server.
void main() {
  late HttpServer server;
  final seen = <Map<String, Object?>>[];

  setUp(() async {
    seen.clear();
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((request) async {
      var bytes = await request.fold<List<int>>([], (a, b) => a..addAll(b));
      final gzipped = request.headers.value('content-encoding') == 'gzip';
      if (gzipped) bytes = gzip.decode(bytes);
      seen.add({
        'method': request.method,
        'path': request.uri.toString(),
        'key': request.headers.value('x-corlex-key'),
        'length': request.headers.contentLength,
        'gzip': gzipped,
        'chunked': request.headers.value('transfer-encoding') == 'chunked',
        'type': request.headers.contentType?.mimeType,
        'body': utf8.decode(bytes),
      });
      request.response
        ..statusCode = request.method == 'POST' ? 413 : 200
        ..headers.set('Retry-After', '7')
        ..headers.set('ETag', '"abc"')
        ..write('{"ok":true}');
      await request.response.close();
    });
  });
  tearDown(() => server.close(force: true));

  Uri url(String path) => Uri.parse('http://127.0.0.1:${server.port}$path');

  test('never forwards project credentials to a redirect destination',
      () async {
    final destination = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final leaked = <String?>[];
    destination.listen((request) async {
      leaked.add(request.headers.value('x-corlex-key'));
      request.response.write('{}');
      await request.response.close();
    });
    final redirect = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    redirect.listen((request) async {
      request.response.statusCode = 302;
      request.response.headers
          .set('Location', 'http://127.0.0.1:${destination.port}/leak');
      await request.response.close();
    });
    try {
      final reply = await IoHttp().get(
          Uri.parse('http://127.0.0.1:${redirect.port}/config'),
          {'X-Corlex-Key': 'fake-project-key'});
      expect(leaked, isEmpty,
          reason: 'a redirect must never receive the project key');
      expect(reply.status, 302);
    } finally {
      await redirect.close(force: true);
      await destination.close(force: true);
    }
  });

  test('decoded streamed responses are capped before retaining excessive data',
      () async {
    final oversized = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    oversized.listen((request) async {
      request.response.headers.set('Content-Encoding', 'gzip');
      request.response.add(gzip.encode(List.filled(1024 * 1024 + 1, 120)));
      await request.response.close();
    });
    try {
      await expectLater(
          IoHttp()
              .get(Uri.parse('http://127.0.0.1:${oversized.port}/config'), {}),
          throwsA(isA<HttpException>()));
    } finally {
      await oversized.close(force: true);
    }
  });

  test('one deadline cancels a slow response even while bytes keep arriving',
      () async {
    final drip = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final closed = Completer<void>();
    drip.listen((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      void markClosed() {
        if (!closed.isCompleted) closed.complete();
      }

      socket.listen((_) {},
          onDone: markClosed, onError: (Object _) => markClosed());
      socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\n');
      try {
        for (var index = 0; index < 100; index++) {
          socket.write('x');
          await socket.flush();
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      } on Object {
        markClosed();
      } finally {
        socket.destroy();
      }
    });
    try {
      await expectLater(
          IoHttp(timeout: const Duration(milliseconds: 150))
              .get(Uri.parse('http://127.0.0.1:${drip.port}/slow'), {}),
          throwsA(isA<TimeoutException>()));
      await closed.future.timeout(const Duration(seconds: 3));
    } finally {
      await drip.close(force: true);
    }
  });

  test(
      'pause cancels an active response, rejects new work and resume starts fresh',
      () async {
    final active = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    final started = Completer<void>();
    final closed = Completer<void>();
    active.listen((request) async {
      final socket = await request.response.detachSocket(writeHeaders: false);
      void done() {
        if (!closed.isCompleted) closed.complete();
        socket.destroy();
      }

      socket.listen((_) {}, onDone: done, onError: (Object _) => done());
      socket.write(
          'HTTP/1.1 200 OK\r\nContent-Length: 100\r\nConnection: close\r\n\r\nx');
      await socket.flush();
      started.complete();
    });
    final http = IoHttp();
    try {
      final pending =
          http.get(Uri.parse('http://127.0.0.1:${active.port}/active'), {});
      final failed = expectLater(pending, throwsA(isA<Exception>()));
      await started.future;
      http.pause();
      await failed;
      await closed.future.timeout(const Duration(seconds: 3));
      await expectLater(
          http.get(url('/paused'), {}), throwsA(isA<HttpException>()));
      expect(seen, isEmpty);
      http.resume();
      expect((await http.get(url('/resumed'), {})).status, 200);
      expect(seen, hasLength(1));
    } finally {
      await active.close(force: true);
    }
  });

  test('post: key in a header, JSON, a known length, answer headers read',
      () async {
    final reply = await IoHttp()
        .post(url('/v1/batch'), '{"events":[]}', {'X-Corlex-Key': 'k'});
    expect(reply.status, 413);
    expect(reply.retryAfter, '7');
    expect(seen.single, containsPair('key', 'k'));
    expect(seen.single, containsPair('type', 'application/json'));
    expect(seen.single, containsPair('gzip', false));
    expect(seen.single, containsPair('chunked', false));
    expect(seen.single['length'], 13);
    expect(seen.single['path'], '/v1/batch',
        reason: 'the key never goes into the URL');
  });

  test('a body over 1 KiB is gzipped and arrives intact', () async {
    final body = jsonEncode({'events': List.generate(40, (i) => 'x' * 100)});
    await IoHttp().post(url('/v1/batch'), body, {'X-Corlex-Key': 'k'});
    expect(seen.single, containsPair('gzip', true));
    expect(seen.single['body'], body);
    expect(seen.single['chunked'], false);
  });

  test('get returns status, ETag and body; a dead server throws', () async {
    final reply =
        await IoHttp().get(url('/v1/config/document'), {'X-Corlex-Key': 'k'});
    expect(reply.status, 200);
    expect(reply.etag, '"abc"');
    expect(reply.body, '{"ok":true}');
    final dead = url('/x');
    await server.close(force: true);
    await expectLater(IoHttp().get(dead, {}), throwsA(isA<SocketException>()));
  });
}
