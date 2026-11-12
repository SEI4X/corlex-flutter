import 'dart:convert';
import 'package:corlex_flutter/src/binding/driver.dart';
import 'package:corlex_flutter/src/client.dart';
import 'package:corlex_flutter/src/crash/native_crash.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'binding_fixture.dart';
import 'native_crash_test.dart' show iosReport, iosId;
import 'support.dart';

void main() {
  test(
      'recovered native headers must match immutable admitted owner and generation',
      () async {
    final driver = BindingDriver('a' * 64, StateFixture());
    // Native scope admission does not make arbitrary file headers trusted.
    final initial = await driver.prepare(ConsentState.granted);
    final h = Harness(),
        client = CorlexClient(
            key: testKey,
            options: const CorlexOptions(configEnabled: false),
            device: FakePlatform.iosInfo,
            http: h.http,
            directory: h.dir,
            store: driver,
            binding: driver);
    final platform = FakePlatform();
    String report(String? owner, String? generation) {
      final lines = iosReport().split('\n'),
          header = jsonDecode(lines.first) as Map;
      if (owner != null) header['binding_owner'] = owner;
      if (generation != null) header['binding_generation'] = generation;
      return [jsonEncode(header), ...lines.skip(1)].join('\n');
    }

    try {
      client.start(initial);
      for (final data in [
        report(null, null),
        report('b' * 64, driver.generation),
        report(driver.owner, '00000000-0000-4000-8000-000000000001')
      ]) {
        platform.pending.add(PendingCrash(iosId, data));
        await sendPendingCrashes(client, platform);
      }
      await client.flush();
      expect(h.http.batches, isEmpty);
      platform.pending
          .add(PendingCrash(iosId, report(driver.owner, driver.generation)));
      await sendPendingCrashes(client, platform);
      await client.flush();
      expect(h.http.batches.single.events.single['event_id'], iosId);
    } finally {
      client.dispose();
      h.dispose();
    }
  });
}
