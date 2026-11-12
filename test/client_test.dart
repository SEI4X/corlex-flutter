import 'dart:io';

import 'package:corlex_flutter/src/client.dart';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

void main() {
  late Harness h;
  tearDown(() => h.dispose());

  test('an event carries the platform facts, build and the Flutter marker',
      () async {
    h = Harness();
    h.client
        .track('purchase', {'plan': 'pro', 'amount': 12.5, 'build': 'spoofed'});
    await h.client.flush();
    final event = h.http.batches.single.events.single;
    expect(event['name'], 'purchase');
    expect(event['event_id'], matches(RegExp(r'^[0-9a-f-]{36}$')));
    expect(event['anonymous_id'], startsWith('a_'));
    expect(event['properties'], {
      'plan': 'pro',
      'amount': 12.5,
      'build': '77', // the SDK's value wins over the app's
      'framework': 'flutter',
    });
    expect(event['context'], {
      'platform': 'ios',
      'os': 'iOS',
      'os_version': '19.1',
      'app_version': '1.4.2',
      'device_model': 'iPhone16,2',
      'locale': 'en-US',
      'sdk': {'name': 'corlex-flutter', 'version': '0.1.0'},
    });
    expect(h.http.batches.single.headers['X-Corlex-Key'], testKey);
    expect(h.http.batches.single.url.toString(),
        'https://ingest.corlex.ru/v1/batch');
  });

  test('a fresh opt-in identity persists across the next restart', () {
    h = Harness(options: const CorlexOptions(configEnabled: false));
    h.client.optOut();
    h.client.optIn();
    h.client.track('after_consent');
    final id = h.saved.single['anonymous_id'];
    h.client.dispose();
    final restarted = Harness(
        directory: h.dir, options: const CorlexOptions(configEnabled: false));
    try {
      restarted.client.track('after_restart');
      expect(restarted.saved.last['anonymous_id'], id);
    } finally {
      restarted.dispose();
    }
  });

  test('Android reports platform android and os Android', () {
    h = Harness(device: FakePlatform.androidInfo);
    h.client.track('opened');
    final context = h.saved.single['context']! as Map;
    expect(context['platform'], 'android');
    expect(context['os'], 'Android');
    expect((h.saved.single['properties']! as Map)['build'], '200');
  });

  test('identify links the user, reset starts a new anonymous person', () {
    h = Harness();
    h.client.identify('u_42', {'plan': 'pro'});
    h.client.track('after_identify');
    final first = h.saved.last['anonymous_id'];
    expect(h.saved.first['name'], 'corlex.identify');
    expect(h.saved.first['user_id'], 'u_42');
    expect(h.saved.first['properties'], containsPair('plan', 'pro'));
    expect(h.saved.last['user_id'], 'u_42');
    h.client.reset();
    h.client.track('after_reset');
    expect(h.saved.last.containsKey('user_id'), isFalse);
    expect(h.saved.last['anonymous_id'], isNot(first));
  });

  test('reset retains original queued identities through a delivery retry',
      () async {
    h = Harness(options: const CorlexOptions(configEnabled: false));
    h.http.replies.add(const HttpReply(503));
    h.client.track('before_reset');
    final previous = Map<String, Object?>.of(h.saved.single);
    h.client.reset();
    h.client.track('after_reset');
    expect(h.saved.first, previous);
    expect(h.saved.last['anonymous_id'], isNot(previous['anonymous_id']));
    await h.client.flush();
    await h.client.flush();
    expect(h.http.batches, hasLength(2));
    expect(h.http.batches[1].events, h.http.batches[0].events);
    expect(h.http.batches[1].events.first['anonymous_id'],
        previous['anonymous_id']);
  });

  test('setUserProperties is corlex.user_props; bad names are dropped', () {
    h = Harness();
    h.client.setUserProperties({'tier': 'gold'});
    h.client.track('Bad Name!');
    h.client.track('x' * 129);
    expect(h.saved.map((e) => e['name']), ['corlex.user_props']);
  });

  test(
      'properties are sanitized: depth, long strings, non-finite numbers, unknown objects',
      () {
    h = Harness();
    h.client.track('e', {
      'long': 'ы' * 800,
      'nan': double.nan,
      'object': Object(),
      'when': DateTime.utc(2026, 1, 2, 3, 4, 5),
      'deep': {
        'a': {
          'b': {
            'c': {'d': 1}
          }
        }
      },
    });
    final props = h.saved.single['properties']! as Map;
    expect((props['long']! as String).length,
        512); // 1024 bytes of two-byte characters
    expect(props['nan'], isNull);
    expect(props.containsKey('object'), isFalse);
    expect(props['when'], '2026-01-02T03:04:05.000Z');
    // properties is level 1: four levels are allowed, the fifth is cut.
    expect(props['deep'], {
      'a': {'b': <String, Object?>{}}
    });
  });

  test('an event over 32 KiB is dropped, the next one is fine', () {
    h = Harness();
    h.client.track('huge', {for (var i = 0; i < 60; i++) 'k$i': 'x' * 1000});
    h.client.track('small');
    expect(h.saved.map((e) => e['name']), ['small']);
  });

  test(
      'a late event keeps its time, id and versions; the same id is queued once',
      () {
    h = Harness();
    final meta = CaptureMeta(
      eventId: '0192f3a0-0000-7000-8000-000000000001',
      timestamp: DateTime.utc(2026, 10, 20, 11, 59, 0, 250),
      appVersion: '1.0.0',
      build: '10',
      osVersion: '18.0',
    );
    h.client.capture('corlex.crash', {'kind': 'native'}, meta);
    h.client.capture('corlex.crash', {'kind': 'native'}, meta);
    final event = h.saved.single;
    expect(event['event_id'], '0192f3a0-0000-7000-8000-000000000001');
    expect(event['timestamp'], '2026-10-20T11:59:00.250Z');
    expect((event['context']! as Map)['app_version'], '1.0.0');
    expect((event['context']! as Map)['os_version'], '18.0');
    expect((event['properties']! as Map)['build'], '10');
  });

  test('a restart finds the identity and the queued events', () {
    h = Harness();
    h.client.identify('u_1');
    h.client.track('queued');
    final dir = h.dir;
    final anon = h.saved.last['anonymous_id'];
    h.client.dispose();
    final again = Harness(directory: dir);
    again.client.track('second');
    final events = again.saved;
    expect(
        events.map((e) => e['name']), ['corlex.identify', 'queued', 'second']);
    expect(events.last['anonymous_id'], anon);
    expect(events.last['user_id'], 'u_1');
    h = again; // dispose removes the directory
  });

  group('consent', () {
    test(
        'pending: no request, no file, events wait in memory and go out in order after optIn',
        () async {
      h = Harness(initial: ConsentState.pending);
      h.client.track('first');
      h.client.track('second');
      await h.client.flush();
      await pumpEventQueue();
      expect(h.http.requests, isEmpty);
      expect(h.dir.listSync(), isEmpty,
          reason: 'nothing may be written without consent');
      expect(h.timers, isEmpty);

      h.client.optIn();
      await h.client.flush();
      expect(h.http.batches.single.events.map((e) => e['name']),
          ['first', 'second']);
      expect(h.queueFile.existsSync(), isTrue);
      expect(h.client.storedConsent, ConsentState.granted);
    });

    test(
        'optOut stops sending, clears the queue and the ids, and survives a restart',
        () async {
      h = Harness();
      h.client.identify('u_1');
      h.client.track('queued');
      h.client.optOut();
      h.client.track('after');
      await h.client.flush();
      expect(h.http.requests, isEmpty);
      expect(h.queueFile.existsSync(), isFalse);
      final store = File('${h.dir.path}/store.json').readAsStringSync();
      expect(store, contains('denied'));
      expect(store, isNot(contains('corlex_aid')));
      expect(store, isNot(contains('u_1')));

      final dir = h.dir;
      h.client.dispose();
      final again = Harness(directory: dir, initial: ConsentState.granted);
      expect(again.client.consent, ConsentState.denied);
      again.client.track('silent');
      expect(again.http.requests, isEmpty);
      h = again;
    });
  });
}
