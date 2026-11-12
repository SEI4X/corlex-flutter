import 'dart:async';
import 'dart:convert';
import 'package:corlex_flutter/src/binding/driver.dart';
import 'package:corlex_flutter/src/client.dart';
import 'package:corlex_flutter/src/crash/native_crash.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'binding_fixture.dart';
import 'native_crash_test.dart' show iosId, iosReport;
import 'support.dart';

class DeferredCrashQueue extends StateFixture {
  final write = Completer<void>();
  @override
  Future<String> exchange(String command) async {
    final input = jsonDecode(command) as Map;
    if ((input['changes'] as Map?)?.containsKey('corlex_queue') ?? false) {
      await write.future;
    }
    return super.exchange(command);
  }
}

void main() {
  for (final failure in [false, true]) {
    test(
        'native receipt waits for durable queue proof (write failure: $failure)',
        () async {
      final native = DeferredCrashQueue(),
          driver = BindingDriver('a' * 64, native);
      final permission = await driver.prepare(ConsentState.granted);
      final h = Harness(),
          client = CorlexClient(
              key: testKey,
              options: const CorlexOptions(configEnabled: false),
              device: FakePlatform.iosInfo,
              http: h.http,
              directory: h.dir,
              store: driver,
              binding: driver);
      client.start(permission);
      final lines = iosReport().split('\n'),
          header = jsonDecode(lines.first) as Map;
      header['binding_owner'] = driver.owner;
      header['binding_generation'] = driver.generation;
      final platform = FakePlatform()
        ..pending.add(PendingCrash(
            iosId, [jsonEncode(header), ...lines.skip(1)].join('\n')));
      final recovering = sendPendingCrashes(client, platform);
      try {
        await pumpEventQueue();
        expect(platform.acked, isEmpty,
            reason: 'Queue persistence is still blocked.');
      } finally {
        native.failWrite = failure;
        native.write.complete();
        await recovering;
        await driver.flush();
        expect(platform.acked, failure ? isEmpty : [iosId]);
        client.dispose();
        h.dispose();
      }
    });
  }
}
