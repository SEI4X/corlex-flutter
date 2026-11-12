import 'dart:convert';
import 'dart:io';
import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:corlex_flutter/src/binding/bridge.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();
  testWidgets(
      'real native protected state isolates credentials and durable refusal',
      (tester) async {
    await tester.pumpWidget(const SizedBox());
    final received = <({String key, List<Map<String, Object?>> events})>[];
    final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    var acceptA = false;
    final keyA = 'ck_test_${'0' * 43}', keyB = 'ck_test_${'b' * 43}';
    server.listen((request) async {
      final bytes =
          await request.fold<List<int>>([], (all, chunk) => all..addAll(chunk));
      final data = request.headers.value('content-encoding') == 'gzip'
          ? gzip.decode(bytes)
          : bytes;
      final body = jsonDecode(utf8.decode(data)) as Map;
      final key = request.headers.value('X-Corlex-Key') ?? '';
      received.add((
        key: key,
        events: (body['events'] as List).cast<Map<String, Object?>>()
      ));
      request.response.statusCode = key == keyA && !acceptA ? 503 : 202;
      request.response.write('{}');
      await request.response.close();
    });
    final base = 'http://127.0.0.1:${server.port}';
    final options = CorlexOptions(
        endpoint: base,
        configEndpoint: base,
        configEnabled: false,
        captureErrors: false,
        captureLifecycle: false,
        batchSize: 500,
        flushInterval: const Duration(hours: 1));
    Future<void> launch(String key) => Corlex.start(key, options: options);
    try {
      final native = MethodChannelPlatform();
      final bridge = await (native as StateBridgeProvider).stateBridge();
      expect(bridge, isNotNull,
          reason:
              'This proof requires the actual rebuilt protectedStorage v2 native module.');
      await launch(keyA);
      // Public cleanup/activation makes repeated runs independent without deleting host files.
      Corlex.optOut();
      await Corlex.flush();
      Corlex.optIn();
      await Corlex.flush();
      received.clear();
      Corlex.track('only_project_a');
      await Corlex.flush();
      expect(received.single.events.single['name'], 'only_project_a');
      final originalId = received.single.events.single['event_id'];
      Corlex.debugReset();
      received.clear();
      await launch(keyB);
      Corlex.track('only_project_b');
      await Corlex.flush();
      expect(
          received
              .expand((batch) => batch.events)
              .map((e) => e['name'])
              .toList(),
          ['only_project_b']);
      Corlex.debugReset();
      received.clear();
      acceptA = true;
      await launch(keyA);
      await Corlex.flush();
      expect(received.single.events.single['event_id'], originalId,
          reason: 'Same owner preserves its original offline event.');
      Corlex.optOut();
      await Corlex.flush();
      Corlex.debugReset();
      received.clear();
      await launch(keyB);
      Corlex.track('must_not_send');
      await Corlex.flush();
      expect(Corlex.consent, ConsentState.denied);
      expect(received, isEmpty);
      Corlex.optIn();
      Corlex.track('fresh_after_explicit_choice');
      await Corlex.flush();
      expect(
          received
              .expand((batch) => batch.events)
              .map((e) => e['name'])
              .toList(),
          ['fresh_after_explicit_choice']);
    } finally {
      Corlex.optOut();
      await Corlex.flush();
      Corlex.debugReset();
      await server.close(force: true);
    }
  }, timeout: const Timeout(Duration(seconds: 90)));
}
