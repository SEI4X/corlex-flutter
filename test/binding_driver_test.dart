import 'dart:convert';
import 'package:corlex_flutter/src/binding/digest.dart';
import 'package:corlex_flutter/src/binding/driver.dart';
import 'package:corlex_flutter/src/binding/protocol.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'binding_fixture.dart';
import 'support.dart' show testKey;

String owner(String key) => bindingDigest(key,
    endpoint: 'https://ingest.example',
    configEndpoint: 'https://config.example')!;
void main() {
  test('isolates owner state while preserving its own restart history',
      () async {
    final bridge = StateFixture(), a = BindingDriver(owner(testKey), bridge);
    await a.prepare(ConsentState.granted);
    a.set('corlex_queue', 'only_a');
    await a.flush();
    final b = BindingDriver(owner('ck_test_${'b' * 43}'), bridge);
    await b.prepare(ConsentState.granted);
    expect(b.get('corlex_queue'), null);
    final restartedA = BindingDriver(a.owner, bridge);
    await restartedA.prepare(ConsentState.granted);
    expect(restartedA.get('corlex_queue'), 'only_a');
    b.deny();
    await b.flush();
    expect(a.get('corlex_queue'), null);
    await b.activate();
    await a.activate();
    expect(a.get('corlex_queue'), null);
  });
  test(
      'pending writes privacy bookkeeping only and explicit activation preserves held-memory generation',
      () async {
    final bridge = StateFixture(), a = BindingDriver(owner(testKey), bridge);
    await a.prepare(ConsentState.pending);
    final generation = a.generation;
    a.set('corlex_aid', 'must_not_persist');
    await a.flush();
    expect(bridge.rows, isEmpty);
    final activated = await a.activate();
    expect(activated.preserveMemory, true);
    expect(a.generation, generation);
  });
  test(
      'unreadable denied privacy cannot become a default grant and explicit fallback never hydrates old data',
      () async {
    final bridge = StateFixture(),
        first = BindingDriver(owner(testKey), bridge);
    await first.prepare(ConsentState.granted);
    first.deny();
    await first.flush();
    bridge.failRead = true;
    final next = BindingDriver(owner('ck_test_${'b' * 43}'), bridge);
    expect(await next.prepare(ConsentState.granted), ConsentState.pending);
    expect(await next.fresh(), false);
    expect((await next.activate()).granted, true);
    expect(await next.fresh(), true);
    expect(next.get('corlex_queue'), null);
    bridge.failRead = false;
    expect(await next.fresh(), false);
  });
  for (final explicit in [false, true]) {
    test(
        'ATT preserves only actual explicit marker on pending restart explicit=$explicit',
        () async {
      var ceiling = ConsentState.granted;
      final bridge = StateFixture(),
          a = BindingDriver(owner(testKey), bridge,
              readCeiling: () async => ceiling);
      await a.prepare(ConsentState.granted);
      if (explicit) await a.activate();
      await a.flush();
      a.set('corlex_queue', 'old_payload');
      await a.flush();
      ceiling = ConsentState.denied;
      expect(await a.fresh(), false);
      expect(bridge.rows.values, isNot(contains('old_payload')));
      ceiling = ConsentState.granted;
      await a.activate(explicit: false);
      await a.flush();
      final next = BindingDriver(a.owner, bridge);
      expect(await next.prepare(ConsentState.pending),
          explicit ? ConsentState.granted : ConsentState.pending);
      next.deny();
      await next.flush();
      expect(bridge.rows.keys.any((k) => k.startsWith('m:')), false);
    });
  }
  test('ATT authorization cannot lift a saved SDK refusal', () async {
    var ceiling = ConsentState.granted;
    final bridge = StateFixture(),
        a = BindingDriver(owner(testKey), bridge,
            readCeiling: () async => ceiling);
    await a.prepare(ConsentState.granted);
    a.deny();
    await a.flush();
    ceiling = ConsentState.denied;
    await a.fresh();
    ceiling = ConsentState.granted;
    expect((await a.activate(explicit: false)).granted, false);
    expect(Privacy.parse(bridge.raw)?.sdkChoice, ConsentState.denied);
  });
  test(
      'strict sidecar and snapshot reject foreign-owner rows and illegal effective grant',
      () {
    final invalid = jsonEncode({
      'generation': '12345678-1234-1234-1234-123456789abc',
      'state': 'granted',
      'sdkChoice': 'denied'
    });
    expect(Privacy.parse(invalid), null);
    final p = Privacy.create(ConsentState.granted, ConsentState.granted);
    expect(
        () => Snapshot.parse(
            jsonEncode({
              'privacy': p.raw,
              'rows': {'s:${'b' * 64}:${p.generation}:corlex_aid': 'foreign'}
            }),
            'a' * 64),
        throwsFormatException);
  });
}
