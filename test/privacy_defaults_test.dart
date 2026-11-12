import 'dart:async';
import 'package:corlex_flutter/src/crash/dart_errors.dart';
import 'package:corlex_flutter/src/crash/dart_stack.dart';
import 'package:corlex_flutter/src/crash/native_crash.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:corlex_flutter/src/screens.dart';
import 'dart:convert';
import 'native_crash_test.dart' show androidReport;
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

class PrivateError {
  int reads = 0;
  @override
  String toString() {
    reads++;
    return 'alex@example.com secret cm_${'a' * 43}';
  }
}

void main() {
  test('default Dart diagnostics do not evaluate private error details', () {
    final h = Harness(), error = PrivateError();
    try {
      DartErrorCapture(h.client).record(
          error, StackTrace.fromString('#0 load (package:app/main.dart:4:2)'),
          source: 'global_handler');
      final props = h.saved.single['properties'] as Map;
      expect(props['message'], 'Error details omitted');
      expect(error.reads, 0);
      expect(props.toString(), isNot(contains('alex@example.com')));
    } finally {
      h.dispose();
    }
  });
  test(
      'default stack locations cannot replay personal paths or credential-like labels',
      () {
    final stack =
        '#0 load (https://example.com/users/alex@example.com.dart:4:2)\n#1 secret (file:///tmp/cm_${'a' * 43}/source.dart:5:3)\n#2 load (package:app/main.dart:6:4)';
    final frames = parseDartStack(stack);
    expect(frames.toString(), isNot(contains('alex@example.com')));
    expect(frames.toString(), isNot(contains('cm_')));
    expect(frames.any((f) => f['file'] == 'package:app/main.dart'), true);
  });
  test(
      'invalid event diagnostics are generic and bounded for distinct private names',
      () {
    final logs = <String>[],
        h = Harness(
            options: const CorlexOptions(debug: true, configEnabled: false));
    try {
      runZoned(() {
        for (var i = 0; i < 10000; i++) {
          h.client.track('alex@example.com_$i');
        }
      },
          zoneSpecification:
              ZoneSpecification(print: (_, __, ___, line) => logs.add(line)));
      expect(logs, hasLength(1));
      expect(logs.join(), isNot(contains('alex@example.com')));
    } finally {
      h.dispose();
    }
  });

  test('explicit error details still scrub known credentials and email', () {
    final h = Harness(options: const CorlexOptions(captureErrorMessages: true)),
        error = PrivateError();
    try {
      DartErrorCapture(h.client).record(error, null, source: 'global_handler');
      final props = h.saved.single['properties'] as Map;
      expect(error.reads, 1);
      expect(props['message'], '[email] secret [credential]');
    } finally {
      h.dispose();
    }
  });
  test(
      'legacy native files drop raw details/frames and preserve unknown release metadata',
      () {
    final value = jsonDecode(androidReport()) as Map;
    value['message'] = 'alex@example.com';
    value['frames'] = [
      'alex@example.com',
      {'fn': 'user.alex@example.com', 'file': '/tmp/private.dart'},
      {'fn': 'app.Widget.render', 'file': 'Widget.kt', 'line': 7}
    ];
    value.remove('app_version');
    value['build'] = '1' * 33;
    final crash = parseNativeReport('Android', jsonEncode(value));
    expect(crash?.properties['message'], 'Error details omitted');
    expect(crash?.properties.toString(), isNot(contains('alex@example.com')));
    expect(crash?.appVersion, '');
    expect(crash?.build, '');
  });

  test(
      'recovered unknown release never borrows the newer launch build in the actual event',
      () async {
    final h = Harness(device: FakePlatform.androidInfo),
        platform = FakePlatform();
    final value = jsonDecode(androidReport()) as Map;
    value.remove('app_version');
    value['build'] = '1' * 33;
    platform.pending
        .add(PendingCrash(value['crash_id'] as String, jsonEncode(value)));
    try {
      await sendPendingCrashes(h.client, platform);
      final event = h.saved.single;
      expect((event['context'] as Map).containsKey('app_version'), false);
      expect((event['properties'] as Map).containsKey('build'), false);
    } finally {
      h.dispose();
    }
  });

  test('route labels redact known contact and credential segments', () {
    expect(screenName('/users/alex@example.com'), '/users/[id]');
    expect(screenName('/users/alex%40example.com'), '/users/[id]');
    expect(screenName('/keys/ck_test_${'a' * 43}'), '/keys/[id]');
  });
}
