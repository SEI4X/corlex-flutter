import 'dart:io';
import 'package:corlex_flutter/src/corlex.dart';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart';

void main() {
  testWidgets(
      'does not replay a prior SDK credential queue under the next project',
      (tester) async {
    final dir = Directory.systemTemp.createTempSync('corlex-binding-test-');
    final platform = FakePlatform(), http = FakeHttp();
    const options = CorlexOptions(
        captureErrors: false, captureLifecycle: false, configEnabled: false);
    try {
      http.fallback = const HttpReply(503);
      await Corlex.start(testKey,
          options: options, platform: platform, http: http, directory: dir);
      Corlex.track('only_project_a');
      await Corlex.flush();
      Corlex.debugReset();
      http.requests.clear();
      http.fallback = const HttpReply(202);
      await Corlex.start('ck_test_${'b' * 43}',
          options: options, platform: platform, http: http, directory: dir);
      Corlex.track('only_project_b');
      await Corlex.flush();
      expect(
          http.batches.expand((r) => r.events).map((e) => e['name']).toList(),
          ['only_project_b']);
    } finally {
      Corlex.debugReset();
      dir.deleteSync(recursive: true);
    }
  });

  for (final stored in ['{"corlex_consent":"denied"}', '{broken']) {
    testWidgets(
        'retains a legacy refusal or fails closed on unreadable legacy choice $stored',
        (tester) async {
      final dir = Directory.systemTemp.createTempSync('corlex-legacy-test-');
      final platform = FakePlatform(), http = FakeHttp();
      File('${dir.path}/store.json').writeAsStringSync(stored);
      try {
        await Corlex.start(testKey,
            options: const CorlexOptions(
                captureErrors: false,
                captureLifecycle: false,
                configEnabled: false),
            platform: platform,
            http: http,
            directory: dir);
        Corlex.track('must_not_send');
        await Corlex.flush();
        expect(
            Corlex.consent,
            stored.startsWith('{broken')
                ? ConsentState.pending
                : ConsentState.denied);
        expect(http.requests, isEmpty);
        expect(File('${dir.path}/store.json').existsSync(), false);
      } finally {
        Corlex.debugReset();
        dir.deleteSync(recursive: true);
      }
    });
  }
}
