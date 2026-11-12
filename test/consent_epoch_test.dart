import 'dart:async';
import 'dart:convert';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/queue.dart';
import 'package:corlex_flutter/src/sender.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

class DelayedHttp extends FakeHttp {
  final first = Completer<HttpReply>();
  @override
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers) {
    requests.add(Request('POST', url, body, headers));
    return requests.length == 1
        ? first.future
        : Future.value(const HttpReply(503));
  }
}

class TwoStageHttp extends FakeHttp {
  final first = Completer<HttpReply>();
  final second = Completer<HttpReply>();
  @override
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers) {
    requests.add(Request('POST', url, body, headers));
    return requests.length == 1 ? first.future : second.future;
  }
}

void main() {
  test('flush after a fresh grant waits for that generation response',
      () async {
    final queue = EventQueue(null)..push({'event_id': 'old'});
    final http = TwoStageHttp();
    final sender = Sender(
        queue: queue,
        http: http,
        endpoint: 'https://ingest.test',
        key: 'fake-key',
        batchSize: 1,
        flushInterval: const Duration(seconds: 30),
        log: (_) {});
    final old = sender.flush();
    sender.stop();
    queue.clear();
    queue.push({'event_id': 'new'});
    sender.resume();
    var finished = false;
    final fresh = sender.flush().then((_) {
      finished = true;
    });
    http.first.complete(const HttpReply(401));
    try {
      await pumpEventQueue();
      expect(http.requests, hasLength(2));
      expect(finished, isFalse,
          reason: 'new flush must wait for the new response');
      http.second.complete(const HttpReply(202));
      await fresh;
      await old;
      expect(queue.size, 0);
    } finally {
      if (!http.second.isCompleted) http.second.complete(const HttpReply(202));
      sender.dispose();
    }
  });

  test(
      'old 401 cannot clear events captured after consent was withdrawn and granted again',
      () async {
    final queue = EventQueue(null)..push({'event_id': 'old'});
    final http = DelayedHttp();
    final sender = Sender(
        queue: queue,
        http: http,
        endpoint: 'https://ingest.test',
        key: 'fake-key',
        batchSize: 1,
        flushInterval: const Duration(seconds: 30),
        log: (_) {});
    final old = sender.flush();
    sender.stop();
    queue.clear();
    queue.push({'event_id': 'new'});
    sender.resume();
    http.first.complete(const HttpReply(401));
    await old;
    await pumpEventQueue();
    expect(queue.has('new'), isTrue);
    expect(
        http.batches.map((request) =>
            (jsonDecode(request.body) as Map)['events'][0]['event_id']),
        ['old', 'new']);
    sender.dispose();
  });
}
