import 'dart:convert';

import 'package:corlex_flutter/src/crash/native_crash.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String iosId = '3f2a1c9e-0000-4000-8000-000000000001';
const String androidId = '3f2a1c9e-0000-4000-8000-000000000002';

/// What the C handler of the iOS SDK writes (see sdk-ios CrashReportReader).
String iosReport({String source = 'signal', String name = 'SIGSEGV'}) => [
      jsonEncode({
        'v': 1,
        'crash_id': iosId,
        'kind': 'native',
        'fatal': true,
        'arch': 'arm64',
        'os_version': '18.2',
        'device_model': 'iPhone16,2',
        'app_version': '1.0.0',
        'build': '12',
        'source': source,
        'name': name,
        'message': 'Signal 11',
        'timestamp_ms': 1761000000000,
      }),
      'F\t3f2a1c9e-1111-2222-3333-444455556666\t0x100a00000\t0x100a1b2c4\tRunner',
      'F\t-\t-\t0x7ff800001234\t-\t_pthread_kill',
      'F\t3f2a1c9e-1111-2222-3333-444455556666\t0x100a00000\tnot-hex\tRunner',
    ].join('\n');

String androidReport() => jsonEncode({
      'v': 1,
      'crash_id': androidId,
      'timestamp_ms': 1761000000000,
      'fatal': true,
      'source': 'java_exception',
      'name': 'a.b.c',
      'message': 'boom',
      'frames': [
        {'fn': 'a.b.c.d', 'file': 'SourceFile', 'line': 12},
      ],
      'app_version': '2.0.0',
      'build': '200',
      'os_version': '14',
      'device_model': 'Pixel 8',
    });

void main() {
  group('parseNativeReport', () {
    test('iOS: the contract frames {image, debug_id, image_addr, addr, fn?}',
        () {
      final crash = parseNativeReport('iOS', iosReport())!;
      expect(crash.crashId, iosId);
      expect(crash.timestamp, DateTime.utc(2025, 10, 20, 22, 40));
      expect(crash.appVersion, '1.0.0');
      expect(crash.build, '12');
      expect(crash.osVersion, '18.2');
      expect(crash.properties, {
        'crash_id': iosId,
        'kind': 'native',
        'fatal': true,
        'name': 'SIGSEGV',
        'message': 'Error details omitted',
        'source': 'signal',
        'frames': [
          {
            'addr': '0x100a1b2c4',
            'debug_id': '3f2a1c9e-1111-2222-3333-444455556666',
            'image_addr': '0x100a00000',
            'image': 'Runner',
          },
          {'addr': '0x7ff800001234', 'fn': '_pthread_kill'},
        ],
        'symbolicated': false,
        'arch': 'arm64',
      });
    });

    test(
        'Android: structured static frames survive and legacy raw cause detail is dropped',
        () {
      final crash = parseNativeReport('Android', androidReport())!;
      expect(crash.properties['source'], 'java_exception');
      expect(crash.properties['kind'], 'native');
      expect(crash.properties['frames'], [
        {'fn': 'a.b.c.d', 'file': 'SourceFile', 'line': 12},
      ]);
      expect(crash.build, '200');
      expect(crash.deviceModel, 'Pixel 8');
    });

    test('damaged, empty or foreign files are ignored', () {
      expect(parseNativeReport('iOS', ''), isNull);
      expect(parseNativeReport('iOS', '{"nope":1}'), isNull);
      expect(parseNativeReport('iOS', 'garbage'), isNull);
      expect(parseNativeReport('Android', '[1]'), isNull);
      expect(
          parseNativeReport(
              'Android', '{"crash_id":"not-a-uuid","timestamp_ms":1}'),
          isNull);
    });

    test('the message is cut to 512 bytes', () {
      final long = jsonEncode({
        'crash_id': androidId,
        'timestamp_ms': 1,
        'message': 'я' * 600,
      });
      final message =
          parseNativeReport('Android', long)!.properties['message']! as String;
      expect(utf8.encode(message).length, lessThanOrEqualTo(512));
    });
  });

  group('sendPendingCrashes', () {
    late Harness h;
    tearDown(() => h.dispose());

    test(
        'queues the crash with its original time, id and the versions of the run that crashed',
        () async {
      h = Harness(); // the current run is 1.4.2 / 77
      final platform = FakePlatform()
        ..pending.add(PendingCrash(iosId, iosReport()));
      await sendPendingCrashes(h.client, platform);
      final event = h.saved.single;
      expect(event['name'], 'corlex.crash');
      expect(event['event_id'], iosId);
      expect(event['timestamp'], '2025-10-20T22:40:00.000Z');
      final context = event['context']! as Map;
      expect(context['app_version'], '1.0.0');
      expect(context['os_version'], '18.2');
      expect(context['platform'], 'ios');
      final props = event['properties']! as Map;
      expect(props['build'], '12');
      expect(props['kind'], 'native');
      expect(props['framework'], 'flutter');
      expect(platform.acked, [iosId],
          reason: 'the file goes after the event is queued');
    });

    test(
        'a crash seen twice is queued once; an unreadable file is acknowledged and dropped',
        () async {
      h = Harness();
      final platform = FakePlatform()
        ..pending.addAll([
          PendingCrash(iosId, iosReport()),
          const PendingCrash('bad', 'junk')
        ]);
      await sendPendingCrashes(h.client, platform);
      platform.pending
          .add(PendingCrash(iosId, iosReport())); // acked-late duplicate
      await sendPendingCrashes(h.client, platform);
      expect(h.saved.length, 1);
      expect(platform.acked, containsAll([iosId, 'bad']));
    });

    test(
        'Android reports are read in the Android format and sent as platform android',
        () async {
      h = Harness(device: FakePlatform.androidInfo);
      final platform = FakePlatform(info: FakePlatform.androidInfo)
        ..pending.add(PendingCrash(androidId, androidReport()));
      await sendPendingCrashes(h.client, platform);
      final event = h.saved.single;
      expect((event['context']! as Map)['platform'], 'android');
      expect((event['context']! as Map)['app_version'], '2.0.0');
      expect((event['properties']! as Map)['source'], 'java_exception');
    });
  });
}
