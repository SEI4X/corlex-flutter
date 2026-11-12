import 'dart:convert';

import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

Map<String, Object?> document({
  int version = 1,
  String etag = '"v1"',
  bool flag = true,
}) =>
    {
      'version': version,
      'etag': etag,
      'params': [
        {'k': 'paywall', 't': 'bool', 'v': flag, 'r': 10000},
        {'k': 'trial_days', 't': 'number', 'v': 7, 'r': 10000},
        {'k': 'ratio', 't': 'number', 'v': 2, 'r': 10000},
        {'k': 'nobody', 't': 'bool', 'v': true, 'r': 0},
        {
          'k': 'ios_only',
          't': 'string',
          'v': 'x',
          'r': 0,
          'o': {'ios': 'yes'}
        },
        {
          'k': 'steps',
          't': 'json',
          'v': ['a', 'b'],
          'r': 10000
        },
        {'k': 'cta', 't': 'string', 'v': 'plain', 'r': 10000},
      ],
      'experiments': [
        {
          'k': 'onboarding_test',
          's': 'salt',
          'v': [
            {'n': 'control', 'b': 5000, 'v': 'a'},
            {'n': 'variant_1', 'b': 10000, 'v': 'b'},
          ],
        },
        {
          'k': 'cta_test',
          's': 'salt2',
          'p': 'cta',
          'v': [
            {'n': 'control', 'b': 5000, 'v': 'buy'},
            {'n': 'variant_1', 'b': 10000, 'v': 'buy now'},
          ],
        },
      ],
    };

HttpReply ok(Map<String, Object?> doc) =>
    HttpReply(200, etag: doc['etag'] as String?, body: jsonEncode(doc));

void main() {
  late Harness h;
  tearDown(() => h.dispose());

  Future<void> settle() => h.client.remote!.ready();

  test(
      'downloads once per launch with the key in a header and no person in the request',
      () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    final get = h.http.requests.single;
    expect(get.method, 'GET');
    expect(get.url.toString(), 'https://config.corlex.ru/v1/config/document');
    expect(get.headers, {'X-Corlex-Key': testKey});
    expect(get.url.query, isEmpty);
    expect(h.client.remote!.get('paywall', false), isTrue);
  });

  test('values: type must match the fallback, rollout and platform rules hold',
      () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    final rc = h.client.remote!;
    expect(rc.get('trial_days', 3), 7);
    expect(rc.get('trial_days', 'three'), 'three',
        reason: 'a string fallback ignores a number');
    expect(rc.get('ratio', 1.5), 2.0,
        reason: 'an int JSON value serves a double fallback');
    expect(rc.get('nobody', false), isFalse, reason: '0 % rollout');
    expect(rc.get('ios_only', 'none'), 'yes',
        reason: 'platform override beats the 0 % rollout');
    expect(rc.get('steps', <Object?>[]), ['a', 'b']);
    expect(rc.get('missing', 'dflt'), 'dflt');
    expect(rc.getAll().keys,
        containsAll(['paywall', 'trial_days', 'ios_only', 'steps']));
    expect(rc.getAll().containsKey('nobody'), isFalse);
  });

  test(
      'a conditional GET: the saved ETag goes in If-None-Match and a 304 changes nothing',
      () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    final dir = h.dir;
    h.client.dispose();

    final again = Harness(directory: dir);
    again.http.replies.add(const HttpReply(304));
    await again.client.remote!.ready();
    expect(again.http.requests.single.headers['If-None-Match'], '"v1"');
    expect(again.client.remote!.get('trial_days', 0), 7,
        reason: 'served from the saved document');
    h = again;
  });

  test('a new document waits for the next launch once a value was read',
      () async {
    h = Harness();
    final updates = <bool>[];
    h.client.remote!.onUpdate((u) => updates.add(u.applied));
    h.http.replies.add(ok(document()));
    await settle();
    expect(h.client.remote!.get('paywall', false), isTrue); // handed out

    h.http.replies.add(ok(document(version: 2, etag: '"v2"', flag: false)));
    await h.client.remote!.refresh();
    expect(h.client.remote!.get('paywall', true), isTrue,
        reason: 'a value must not flip mid-session');
    expect(updates, [true, false]);

    final dir = h.dir;
    h.client.dispose();
    final next = Harness(directory: dir);
    next.http.replies.add(const HttpReply(304));
    await next.client.remote!.ready();
    expect(next.client.remote!.get('paywall', true), isFalse,
        reason: 'the next launch applies it');
    h = next;
  });

  test('bad answers and network errors keep what the app has', () async {
    h = Harness();
    h.http.replies.addAll([
      const HttpReply(200, body: '{"nonsense": true}'),
      const HttpReply(500),
    ]);
    await settle();
    expect(h.client.remote!.get('paywall', false), isFalse);
    await h.client.remote!.refresh();
    h.http.replies.add(Exception('offline'));
    await h.client.remote!.refresh();
    expect(h.client.remote!.getAll(), isEmpty);
  });

  test(
      'experiment(): the variant is stable and the exposure is sent once per session',
      () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    final first = h.client.remote!.experiment('onboarding_test');
    final again = h.client.remote!.experiment('onboarding_test');
    expect(first, isNotNull);
    expect(again!.variant, first!.variant);
    expect(h.client.remote!.experiment('unknown_test'), isNull);
    final exposures =
        h.saved.where((e) => e['name'] == 'corlex.exposure').toList();
    expect(exposures.length, 1);
    expect(exposures.single['properties'],
        containsPair('experiment', 'onboarding_test'));
    expect(
        exposures.single['properties'], containsPair('variant', first.variant));
  });

  test('reading a parameter under test is the exposure; getAll is not',
      () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    h.client.remote!.getAll();
    expect(h.saved.where((e) => e['name'] == 'corlex.exposure'), isEmpty);
    final value = h.client.remote!.get('cta', 'x');
    expect(value, anyOf('buy', 'buy now'));
    expect(h.client.remote!.get('cta', 'x'), value);
    final exposure = h.saved.singleWhere((e) => e['name'] == 'corlex.exposure');
    expect((exposure['properties']! as Map)['experiment'], 'cta_test');
    expect(h.client.remote!.get('cta', 5), 5,
        reason: 'wrong type: fallback, no exposure');
  });

  test('reset() starts a new person, who may be exposed again', () async {
    h = Harness();
    h.http.replies.add(ok(document()));
    await settle();
    h.client.remote!.experiment('onboarding_test');
    h.client.reset();
    h.client.remote!.experiment('onboarding_test');
    expect(h.saved.where((e) => e['name'] == 'corlex.exposure').length, 2);
  });

  test('no consent: nothing is downloaded and every read is the fallback',
      () async {
    h = Harness(initial: ConsentState.pending);
    await settle();
    await pumpEventQueue();
    expect(h.http.requests, isEmpty);
    expect(h.client.remote!.get('paywall', false), isFalse);
    expect(h.client.remote!.experiment('onboarding_test'), isNull);
  });

  test('optIn starts the download; optOut forgets the saved document',
      () async {
    h = Harness(initial: ConsentState.pending);
    h.http.replies.add(ok(document()));
    h.client.optIn();
    await settle();
    expect(h.http.requests.where((r) => r.method == 'GET').length, 1);
    expect(h.client.remote!.get('paywall', false), isTrue);
    h.client.optOut();
    expect(h.client.remote!.getAll(), isEmpty);
    expect(h.dir.listSync().whereType<dynamic>().map((f) => f.path).join(),
        isNot(contains('queue')));
  });

  test('configEnabled: false never downloads', () async {
    h = Harness(options: const CorlexOptions(configEnabled: false));
    await pumpEventQueue();
    expect(h.http.requests, isEmpty);
  });
}
