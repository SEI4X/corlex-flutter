import 'dart:convert';
import 'package:corlex_flutter/src/binding/driver.dart';
import 'package:corlex_flutter/src/binding/http.dart';
import 'package:corlex_flutter/src/client.dart';
import 'support.dart';
import 'package:corlex_flutter/src/binding/protocol.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'binding_fixture.dart';

class MemoryFloor extends StateFixture {
  String? disk = '';
  bool failDisk = false;
  @override
  String? current() => disk;
  @override
  void publish(String next) {
    super.publish(next);
    if (!failDisk) disk = next;
  }

  @override
  Future<String> revoke(String expected, String record) async {
    final result = await super.revoke(expected, record);
    if (failDisk) throw StateError('synthetic disk failure');
    return result;
  }

  @override
  Future<String> exchange(String command) async {
    final value = jsonDecode(command) as Map;
    if (failDisk &&
        value['privacy'] != null &&
        Privacy.parse(value['privacy'] as String)?.state ==
            ConsentState.granted) {
      throw StateError('synthetic disk failure');
    }
    return super.exchange(command);
  }
}

class SupersededRefusal extends StateFixture {
  int calls = 0;
  @override
  Future<String> revoke(String expected, String record) async {
    calls++;
    raw = Privacy.create(ConsentState.granted, ConsentState.granted).raw;
    return raw!;
  }
}

class BlockedMemoryFloor extends MemoryFloor {
  @override
  Future<String> exchange(String command) async {
    if (failDisk) throw StateError('synthetic IO failure');
    return super.exchange(command);
  }

  @override
  Future<String> observe(String expected, String ceiling) async {
    if (failDisk) throw StateError('synthetic IO failure');
    return super.observe(expected, ceiling);
  }
}

class MissingMarkerRead extends MemoryFloor {
  @override
  Future<String> fresh() async => raw ?? '';
}

void main() {
  test(
      'observed native RAM refusal outranks unchanged old granted sidecar after IO failure',
      () async {
    final native = MemoryFloor(),
        a = BindingDriver('a' * 64, native),
        b = BindingDriver('b' * 64, native);
    await a.prepare(ConsentState.granted);
    await b.prepare(ConsentState.granted);
    final oldDisk = native.disk;
    native.failDisk = true;
    a.deny();
    await a.flush();
    expect(native.disk, oldDisk);
    expect(Privacy.parse(native.raw)?.state, ConsentState.denied);
    expect(await b.fresh(), false);
    expect(b.consent, ConsentState.denied);
    final restarted = BindingDriver('c' * 64, native);
    expect(await restarted.prepare(ConsentState.granted), ConsentState.denied);
  });
  test('does not retry a stale refusal against newer grant metadata', () async {
    final native = SupersededRefusal(), a = BindingDriver('a' * 64, native);
    await a.prepare(ConsentState.granted);
    a.deny();
    await a.flush();
    expect(native.calls, 1);
    expect(Privacy.parse(native.raw)?.state, ConsentState.granted);
    expect(a.consent, ConsentState.denied);
  });
  test('rejects duplicate decoded control keys before last-wins JSON decoding',
      () {
    final generation =
        Privacy.create(ConsentState.granted, ConsentState.granted).generation;
    for (final key in ['state', r'st\u0061te']) {
      final raw =
          '{"generation":"$generation","state":"denied","$key":"granted","sdkChoice":"granted"}';
      expect(Privacy.parse(raw), null);
    }
  });

  test(
      'explicit memory-only SDK choice activates fresh runtime after real ATT authorization',
      () async {
    var ceiling = ConsentState.denied;
    final native = BlockedMemoryFloor(),
        driver =
            BindingDriver('a' * 64, native, readCeiling: () async => ceiling);
    final initial = await driver.prepare(ConsentState.granted),
        h = Harness(options: const CorlexOptions(configEnabled: false));
    final http = FakeHttp(),
        client = CorlexClient(
            key: testKey,
            options: const CorlexOptions(configEnabled: false),
            device: FakePlatform.iosInfo,
            http: BoundHttp(http, driver),
            directory: h.dir,
            store: driver,
            binding: driver);
    try {
      client.start(initial);
      native.failDisk = true;
      client.optIn();
      await client.flush();
      expect(client.consent, ConsentState.denied);
      ceiling = ConsentState.granted;
      await client.refreshBindingCeiling();
      client.track('fresh_memory_after_authorization');
      await client.flush();
      expect(client.consent, ConsentState.granted);
      expect(driver.persistent, false);
      expect(
          http.batches
              .expand((batch) => batch.events)
              .map((e) => e['name'])
              .toList(),
          ['fresh_memory_after_authorization']);
    } finally {
      client.dispose();
      h.dispose();
    }
  });

  test('known effective native denial survives marker snapshot IO failure',
      () async {
    final native = MissingMarkerRead();
    native.disk =
        Privacy.create(ConsentState.granted, ConsentState.granted).raw;
    native.raw = Privacy.create(ConsentState.granted, ConsentState.denied).raw;
    native.failRead = true;
    final driver = BindingDriver('a' * 64, native);
    expect(await driver.prepare(ConsentState.granted), ConsentState.denied);
    expect(driver.consent, ConsentState.denied);
  });
}
