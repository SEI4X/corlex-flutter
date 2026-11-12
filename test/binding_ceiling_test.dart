import 'dart:async';
import 'package:corlex_flutter/src/binding/driver.dart';
import 'package:corlex_flutter/src/binding/protocol.dart';
import 'package:corlex_flutter/src/binding/http.dart';
import 'package:corlex_flutter/src/client.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'binding_fixture.dart';
import 'support.dart';

class RacingCeiling extends StateFixture {
  int calls = 0;
  @override
  Future<String> observe(String expected, String ceiling) async {
    if (calls++ == 0) {
      raw = Privacy.create(ConsentState.granted, ConsentState.granted).raw;
      return raw!;
    }
    return super.observe(expected, ceiling);
  }
}

class BrokenObservation extends StateFixture {
  @override
  Future<String> observe(String expected, String ceiling) async =>
      throw StateError('synthetic private IO details');
}

void main() {
  test('older ATT authorization cannot replace a newer denial observation',
      () async {
    final native = StateFixture();
    Future<ConsentState> Function() read = () async => ConsentState.granted;
    final driver = BindingDriver('a' * 64, native, readCeiling: () => read());
    await driver.prepare(ConsentState.granted);
    final older = Completer<ConsentState>();
    var calls = 0;
    read =
        () => calls++ == 0 ? older.future : Future.value(ConsentState.denied);
    final first = driver.fresh();
    await Future<void>.delayed(Duration.zero);
    await driver.fresh();
    older.complete(ConsentState.granted);
    await first;
    expect(Privacy.parse(native.raw)?.state, ConsentState.denied);
    expect(driver.consent, ConsentState.denied);
  });
  test(
      'unchanged authorized ATT cannot silently reactivate a stale credential generation',
      () async {
    final native = StateFixture(), http = FakeHttp();
    final a = BindingDriver('a' * 64, native,
        readCeiling: () async => ConsentState.granted);
    await a.prepare(ConsentState.granted);
    final h = Harness();
    final client = CorlexClient(
        key: testKey,
        options: const CorlexOptions(configEnabled: false),
        device: FakePlatform.iosInfo,
        http: BoundHttp(http, a),
        directory: h.dir,
        store: a,
        binding: a);
    try {
      client.start(ConsentState.granted);
      final b = BindingDriver('b' * 64, native);
      await b.prepare(ConsentState.granted);
      b.deny();
      await b.flush();
      await b.activate();
      expect(client.consent, ConsentState.pending);
      await client.refreshBindingCeiling();
      client.track('must_wait_explicit_choice');
      await client.flush();
      expect(client.consent, ConsentState.pending);
      expect(http.requests, isEmpty);
    } finally {
      client.dispose();
      h.dispose();
    }
  });

  test(
      'retries an observational floor after a concurrent native publication wins its first CAS',
      () async {
    var state = ConsentState.granted;
    final native = RacingCeiling(), driver = BindingDriver('a' * 64, null);
    final live =
        BindingDriver(driver.owner, native, readCeiling: () async => state);
    await live.prepare(ConsentState.granted);
    state = ConsentState.denied;
    expect(await live.fresh(), false);
    expect(Privacy.parse(native.raw)?.state, ConsentState.denied);
    expect(native.calls, 2);
  });
  test(
      'native observation IO failure never escapes explicit fresh memory activation',
      () async {
    final native = BrokenObservation()
      ..raw = Privacy.create(ConsentState.granted, ConsentState.denied).raw;
    final driver = BindingDriver('a' * 64, native,
        readCeiling: () async => ConsentState.granted);
    await driver.prepare(ConsentState.granted);
    native.failWrite = true;
    expect((await driver.activate()).granted, true);
    expect(driver.persistent, false);
  });
}
