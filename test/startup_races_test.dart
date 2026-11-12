import 'dart:async';
import 'dart:io';
import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/widgets.dart';
import 'native_crash_test.dart' show iosId, iosReport;
import 'support.dart';

class DeferredPlatform extends FakePlatform {
  Completer<String?>? att;
  Completer<DeviceInfo>? device;
  Completer<List<PendingCrash>>? crashes;
  bool askedAtt = false, askedDevice = false, askedCrashes = false;
  @override
  Future<String?> trackingStatus() {
    askedAtt = true;
    return att?.future ?? super.trackingStatus();
  }

  @override
  Future<DeviceInfo> deviceInfo() {
    askedDevice = true;
    return device?.future ?? super.deviceInfo();
  }

  @override
  Future<List<PendingCrash>> takePendingCrashes({CrashScope? scope}) {
    askedCrashes = true;
    return crashes?.future ?? super.takePendingCrashes(scope: scope);
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeHttp http;
  late DeferredPlatform platform;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('corlex_startup_race_');
    http = FakeHttp();
    platform = DeferredPlatform();
  });
  tearDown(() {
    Corlex.debugReset();
    dir.deleteSync(recursive: true);
  });
  Future<void> start({StartConsent consent = StartConsent.granted}) =>
      Corlex.start(testKey,
          platform: platform,
          http: http,
          directory: dir,
          options: CorlexOptions(
              consent: consent, batchSize: 1, configEnabled: false));

  test('invalid SDK credentials and endpoints stop before platform or storage',
      () async {
    for (final key in [
      '',
      'cm_secret',
      'sk-provider',
      '$testKey\n',
      '${testKey}x'
    ]) {
      await Corlex.start(key, platform: platform, http: http, directory: dir);
      expect(platform.askedDevice, isFalse);
      expect(dir.listSync(), isEmpty);
      expect(http.requests, isEmpty);
    }
    for (final endpoint in [
      'http://remote.example.test',
      'https://u:p@example.test',
      'https://@example.test',
      'https://example.test?q=x',
      'https://example.test#x',
      'https://example.test:0'
    ]) {
      await Corlex.start(testKey,
          options: CorlexOptions(endpoint: endpoint),
          platform: platform,
          http: http,
          directory: dir);
      expect(platform.askedDevice, isFalse, reason: endpoint);
      expect(dir.listSync(), isEmpty);
      expect(http.requests, isEmpty);
    }
  });

  test('late authorized ATT cannot overwrite optOut during start', () async {
    platform.att = Completer<String?>();
    final pending = start(consent: StartConsent.att);
    await pumpEventQueue();
    expect(platform.askedAtt, isTrue);
    Corlex.optOut();
    platform.att!.complete('authorized');
    await pending;
    await Corlex.flush();
    expect(Corlex.consent, ConsentState.denied);
    expect(http.requests, isEmpty);
    expect(platform.capture, isNot(contains(true)));
  });
  test('disposal while ATT awaits cannot revive obsolete client', () async {
    platform.att = Completer<String?>();
    final pending = start(consent: StartConsent.att);
    await pumpEventQueue();
    Corlex.debugReset();
    platform.att!.complete('authorized');
    await pending;
    await pumpEventQueue();
    expect(http.requests, isEmpty);
    expect(platform.capture, isNot(contains(true)));
    expect(Corlex.consent, ConsentState.pending);
  });
  test('disposal while deviceInfo awaits reserves no later SDK instance',
      () async {
    platform.device = Completer<DeviceInfo>();
    final pending = start();
    expect(platform.askedDevice, isTrue);
    Corlex.debugReset();
    platform.device!.complete(FakePlatform.iosInfo);
    await pending;
    await pumpEventQueue();
    expect(http.requests, isEmpty);
    expect(platform.capture, isEmpty);
    expect(Corlex.consent, ConsentState.pending);
  });
  test('optOut while deviceInfo awaits is applied before runtime startup',
      () async {
    platform.device = Completer<DeviceInfo>();
    final pending = start();
    Corlex.optOut();
    platform.device!.complete(FakePlatform.iosInfo);
    await pending;
    expect(Corlex.consent, ConsentState.denied);
    expect(http.requests, isEmpty);
    expect(platform.capture, isNot(contains(true)));
  });

  test('old foreground ATT result cannot override a newer explicit choice',
      () async {
    platform.tracking = 'notDetermined';
    await start(consent: StartConsent.att);
    platform.att = Completer<String?>();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpEventQueue();
    Corlex.optOut();
    Corlex.optIn();
    platform.att!.complete('denied');
    await pumpEventQueue();
    expect(Corlex.consent, ConsentState.denied);
    expect(platform.state.raw, contains('"sdkChoice":"granted"'));
    platform.att = null;
    platform.tracking = 'authorized';
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await pumpEventQueue();
    expect(Corlex.consent, ConsentState.granted);
  });

  test('obsolete native recovery cannot capture or acknowledge crashes',
      () async {
    platform.crashes = Completer<List<PendingCrash>>();
    final pending = start();
    await pumpEventQueue();
    expect(platform.askedCrashes, isTrue);
    Corlex.debugReset();
    platform.crashes!.complete([PendingCrash(iosId, iosReport())]);
    await pending;
    expect(platform.acked, isEmpty);
    expect(
        http.batches
            .expand((r) => r.events)
            .where((e) => e['name'] == 'corlex.crash'),
        isEmpty);
  });
}
