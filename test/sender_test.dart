import 'dart:io';
import 'dart:math';

import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:corlex_flutter/src/sender.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  test('parseRetryAfter reads seconds and caps at five minutes', () {
    expect(parseRetryAfter('7'), const Duration(seconds: 7));
    expect(parseRetryAfter(' 12 '), const Duration(seconds: 12));
    expect(parseRetryAfter('99999'), const Duration(minutes: 5));
    expect(parseRetryAfter('Wed, 21 Oct 2026 07:28:00 GMT'), isNull);
    expect(parseRetryAfter(null), isNull);
  });

  test(
      'backoffDelay doubles, is jittered inside [ceiling/2, ceiling] and stops at a minute',
      () {
    final random = Random(1);
    for (var attempt = 1; attempt <= 12; attempt++) {
      final ceiling = min(1000 * pow(2, attempt - 1).toInt(), 60000);
      final delay = backoffDelay(attempt, random).inMilliseconds;
      expect(delay, inInclusiveRange(ceiling ~/ 2, ceiling));
    }
  });

  group('delivery', () {
    late Harness h;
    tearDown(() => h.dispose());

    List<String> ids(Request r) =>
        [for (final e in r.events) e['event_id']! as String];

    test('a partial batch waits for the interval; a full one goes at once',
        () async {
      h = Harness(options: const CorlexOptions(batchSize: 3));
      h.client.track('a');
      h.client.track('b');
      expect(h.http.requests, isEmpty);
      expect(h.active.single.delay, const Duration(seconds: 5));
      h.client.track('c'); // full batch
      await pumpEventQueue();
      expect(
          h.http.batches.single.events.map((e) => e['name']), ['a', 'b', 'c']);
      expect(h.saved, isEmpty, reason: 'delivered events leave the queue file');
    });

    test(
        'a 5xx keeps the events, honours Retry-After and resends the same event_ids',
        () async {
      h = Harness();
      h.client.track('a');
      h.client.track('b');
      h.http.replies.add(const HttpReply(503, retryAfter: '30'));
      await h.client.flush();
      expect(h.saved.length, 2);
      final retry = h.active.single;
      expect(retry.delay, const Duration(seconds: 30),
          reason: 'Retry-After beats a shorter backoff');

      retry.fire();
      await pumpEventQueue();
      expect(h.http.batches.length, 2);
      expect(ids(h.http.batches[1]), ids(h.http.batches[0]));
      expect(h.saved, isEmpty);
    });

    test('blocked redirect retains events for retry', () async {
      h = Harness();
      h.client.track('opened');
      h.http.replies.add(const HttpReply(307));
      await h.client.flush();
      expect(h.saved.length, 1);
      expect(h.active, hasLength(1));
    });

    test('a network failure backs off with growing delays and then recovers',
        () async {
      h = Harness();
      h.client.track('a');
      h.http.replies.addAll(
          [const SocketException('down'), const SocketException('down')]);
      await h.client.flush();
      final first = h.active.single.delay;
      expect(first.inMilliseconds, inInclusiveRange(500, 1000));
      h.active.single.fire();
      await pumpEventQueue();
      final second = h.active.single.delay;
      expect(second.inMilliseconds, inInclusiveRange(1000, 2000));
      h.active.single.fire();
      await pumpEventQueue();
      expect(h.saved, isEmpty);
      expect(h.http.batches.length, 3);
    });

    test('no new timer is armed while backing off', () async {
      h = Harness();
      h.client.track('a');
      h.http.replies.add(const HttpReply(500));
      await h.client.flush();
      final armed = h.active.length;
      h.client.track('b');
      expect(h.active.length, armed);
    });

    test('a 413 halves the batch until it fits, then the limit grows back',
        () async {
      h = Harness(options: const CorlexOptions(batchSize: 8));
      h.http.replies.addAll([const HttpReply(413), const HttpReply(413)]);
      for (var i = 0; i < 8; i++) {
        h.client.track('e$i');
      }
      await pumpEventQueue();
      final sizes = h.http.batches.map((r) => r.events.length).toList();
      expect(sizes, [8, 4, 2, 4, 2],
          reason: 'each 413 halves the batch; every success doubles it back');
      expect(h.saved, isEmpty);
    });

    test('a 413 on a single event drops it; other 4xx drop the batch',
        () async {
      h = Harness();
      h.client.track('a');
      h.http.replies.add(const HttpReply(413));
      await h.client.flush();
      expect(h.saved, isEmpty);

      h.client.track('b');
      h.http.replies.add(const HttpReply(400));
      await h.client.flush();
      expect(h.saved, isEmpty);
      expect(h.active, isEmpty, reason: 'a final 4xx is not retried');
    });

    test('401 stops sending for good and clears the queue', () async {
      h = Harness();
      h.client.track('a');
      h.http.replies.add(const HttpReply(401));
      await h.client.flush();
      expect(h.saved, isEmpty);
      h.client.track('b');
      await h.client.flush();
      expect(h.http.batches.length, 1);
    });

    test('concurrent flushes share one run', () async {
      h = Harness();
      h.client.track('a');
      final a = h.client.flush();
      final b = h.client.flush();
      expect(identical(a, b), isTrue);
      await Future.wait([a, b]);
      expect(h.http.batches.length, 1);
    });
  });
}
