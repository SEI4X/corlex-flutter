import 'dart:async';
import 'dart:convert';
import 'package:corlex_flutter/src/config/remote_config.dart';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'remote_config_test.dart' show document;
import 'support.dart' show FakeHttp, testKey;

RemoteConfig config(Http http, [KeyValueStore? store]) => RemoteConfig(
      store: store ?? MemoryStore(),
      http: http,
      platforms: ['flutter', 'ios'],
      endpoint: 'https://config.example',
      key: testKey,
      live: true,
      timeout: const Duration(milliseconds: 50),
      idOf: () => 'synthetic-person',
      expose: (_, __) {},
      log: (_) {},
    );

class DeferredHttp extends FakeHttp {
  final pending = <Completer<HttpReply>>[];
  @override
  Future<HttpReply> get(Uri url, Map<String, String> headers) {
    final reply = Completer<HttpReply>();
    pending.add(reply);
    return reply.future;
  }
}

void main() {
  for (final malformed in [
    {'k': 'bad', 's': 'salt', 'v': 'wrong'},
    {
      'k': 'bad',
      's': 'salt',
      'v': [
        {'n': 'x', 'b': 0, 'v': true},
        {'n': 'y', 'b': 10000, 'v': false}
      ]
    },
    {
      'k': '__proto__',
      's': 'salt',
      'v': [
        {'n': 'x', 'b': 5000, 'v': true},
        {'n': 'y', 'b': 10000, 'v': false}
      ]
    },
  ]) {
    test(
        'rejects malformed experiment $malformed without host getter exceptions',
        () async {
      final http = FakeHttp(), rc = config(http);
      final doc = document()..['experiments'] = [malformed];
      http.replies.add(HttpReply(200, body: jsonEncode(doc)));
      rc.start();
      await rc.ready();
      expect(rc.getAll(), isEmpty);
      expect(rc.get('paywall', false), false);
      expect(rc.experiment('bad'), isNull);
      rc.destroy();
    });
  }
  for (final tag in ['bad\u0000tag', 'é', '😄', '']) {
    test('rejects downloaded and cached unsendable ETag ${jsonEncode(tag)}',
        () async {
      final http = FakeHttp(), store = MemoryStore(), doc = document(etag: tag);
      store.set(configKey, jsonEncode({'etag': tag, 'doc': doc}));
      http.replies.add(HttpReply(200, body: jsonEncode(doc)));
      final rc = config(http, store)..start();
      await rc.ready();
      expect(http.requests.single.headers.containsKey('If-None-Match'), false);
      expect(rc.getAll(), isEmpty);
      expect(store.get(configKey), isNull);
      rc.destroy();
    });
  }
  for (final body in [
    '{"version":1,"etag":"ok","params":[],"params":[{"k":"x","t":"bool","v":true,"r":10000}]}',
    jsonEncode(document()..['extra'] = List.filled(1024 * 1024, 'x').join()),
    '{"version":1,"etag":"ok","params":[],"extra":${'[' * 17}0${']' * 17}}',
  ]) {
    test('bounds and rejects ambiguous downloaded JSON (${body.length} chars)',
        () async {
      final http = FakeHttp()..replies.add(HttpReply(200, body: body));
      final store = MemoryStore();
      final rc = config(http, store)..start();
      await rc.ready();
      expect(rc.getAll(), isEmpty);
      expect(store.get(configKey), isNull);
      rc.destroy();
    });
  }
  test(
      'throwing update listener cannot reject refresh or skip another listener',
      () async {
    final http = FakeHttp()
      ..replies.add(HttpReply(200, body: jsonEncode(document())));
    final rc = config(http);
    var seen = 0;
    rc.onUpdate((_) => throw StateError('synthetic sensitive details'));
    rc.onUpdate((_) => seen++);
    rc.start();
    await expectLater(rc.refresh(), completes);
    expect(seen, 1);
    rc.destroy();
  });
  test(
      'regrant starts fresh immediately while the earlier generation remains pending',
      () async {
    final http = DeferredHttp(), rc = config(http);
    rc.start();
    final old = rc.refresh();
    expect(http.pending.length, 1);
    rc.stop(wipe: true);
    rc.start();
    final current = rc.refresh();
    expect(http.pending.length, 2);
    http.pending[1]
        .complete(HttpReply(200, body: jsonEncode(document(version: 2))));
    await current;
    http.pending[0].complete(
        HttpReply(200, body: jsonEncode(document(version: 1, flag: false))));
    await old;
    expect(rc.get('paywall', false), true);
    rc.destroy();
  });
}
