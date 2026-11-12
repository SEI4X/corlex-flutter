import 'dart:convert';
import 'dart:io';

import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'native_crash_test.dart' show iosId, iosReport;
import 'support.dart';

// Models native scoped recovery; legacy unbound parser tests use FakePlatform directly.
class ScopedCrashPlatform extends FakePlatform {
  @override
  Future<List<PendingCrash>> takePendingCrashes({CrashScope? scope}) async => [
        for (final item in await super.takePendingCrashes(scope: scope))
          if (scope == null) item else _bound(item, scope),
      ];
  PendingCrash _bound(PendingCrash item, CrashScope scope) {
    final lines = item.data.split('\n'),
        header = jsonDecode(lines.first) as Map;
    header['binding_owner'] = scope.owner;
    header['binding_generation'] = scope.generation;
    return PendingCrash(
        item.id, [jsonEncode(header), ...lines.skip(1)].join('\n'));
  }
}

void main() {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;
  late FakeHttp http;
  late FakePlatform platform;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('corlex_facade_');
    http = FakeHttp();
    platform = ScopedCrashPlatform();
  });
  tearDown(() {
    Corlex.debugReset();
    dir.deleteSync(recursive: true);
  });

  Future<void> start([CorlexOptions options = const CorlexOptions()]) =>
      Corlex.start(testKey,
          options: options, platform: platform, http: http, directory: dir);

  List<String> sentNames() => [
        for (final r in http.batches)
          for (final e in r.events) e['name']! as String,
      ];

  test(
      'before start every call is a harmless no-op and reads return the fallback',
      () async {
    Corlex.track('x');
    Corlex.identify('u');
    Corlex.screen('/home');
    Corlex.recordError(StateError('x'), null);
    expect(Corlex.flag('paywall', true), isTrue);
    expect(Corlex.config.get('days', 7), 7);
    expect(Corlex.config.getAll(), isEmpty);
    expect(Corlex.experiment('t'), isNull);
    await Corlex.config.ready();
    await Corlex.config.refresh();
    await Corlex.flush();
    expect(http.requests, isEmpty);
  });

  test('start: app_open, native crashes of the last launch, then delivery',
      () async {
    platform.pending.add(PendingCrash(iosId, iosReport()));
    await start();
    Corlex.track('hello', {'n': 1});
    await Corlex.flush();
    expect(sentNames(), ['corlex.crash', 'app_open', 'hello']);
    expect(platform.capture, [true]);
    expect(platform.acked, [iosId]);
    final crash = http.batches.first.events.first;
    expect(crash['event_id'], iosId);
    expect(crash['timestamp'], '2025-10-20T22:40:00.000Z');
    expect(http.batches.first.headers['X-Corlex-Key'], testKey);
  });

  test('start twice does nothing the second time; an empty key does not start',
      () async {
    await start();
    await start();
    await Corlex.flush();
    expect(sentNames().where((n) => n == 'app_open').length, 1);
    Corlex.debugReset();
    await Corlex.start('', platform: platform, http: http, directory: dir);
    expect(Corlex.consent, ConsentState.pending, reason: 'not started');
  });

  test('app lifecycle: background flushes, foreground follows', () async {
    await start();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused); // repeated: one event
    await Corlex.flush();
    binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await Corlex.flush();
    expect(sentNames(), ['app_open', 'app_background', 'app_foreground']);
  });

  test('captureLifecycle: false sends no automatic events', () async {
    await start(const CorlexOptions(captureLifecycle: false));
    binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    await Corlex.flush();
    expect(http.requests, isEmpty);
  });

  test(
      'screen: one screen_view per change, with previous_screen and ids replaced',
      () async {
    await start(const CorlexOptions(captureLifecycle: false));
    Corlex.screen('/home');
    Corlex.screen('/home');
    Corlex.screen('/user/12345?tab=1', source: 'navigator');
    await Corlex.flush();
    final events = http.batches.single.events;
    expect(events.map((e) => (e['properties']! as Map)['screen']),
        ['/home', '/user/[id]']);
    expect(events[1]['properties'], containsPair('previous_screen', '/home'));
    expect(events[1]['properties'], containsPair('source', 'navigator'));
  });

  test(
      'recordError and Dart handlers produce corlex.crash; captureErrors: false installs nothing',
      () async {
    await start(const CorlexOptions(captureLifecycle: false));
    Corlex.recordError(StateError('caught'),
        StackTrace.fromString('#0 f (package:a/a.dart:1:2)'),
        fatal: true);
    await Corlex.flush();
    final crash = http.batches.single.events.single;
    expect((crash['properties']! as Map)['fatal'], true);
    expect((crash['properties']! as Map)['kind'], 'js');

    Corlex.debugReset();
    final other = FakePlatform();
    await Corlex.start(testKey,
        options:
            const CorlexOptions(captureErrors: false, captureLifecycle: false),
        platform: other,
        http: http,
        directory: dir);
    expect(other.capture, isEmpty);
    Corlex.recordError(StateError('ignored'), null);
  });

  group('consent', () {
    test(
        'pending: silent, native capture off; optIn turns it on and sends in order',
        () async {
      await start(const CorlexOptions(consent: StartConsent.pending));
      Corlex.track('early');
      await Corlex.flush();
      expect(http.requests, isEmpty);
      expect(platform.capture, isNot(contains(true)));
      expect(Corlex.consent, ConsentState.pending);

      Corlex.optIn();
      await Corlex.flush();
      await pumpEventQueue();
      expect(platform.capture.where((enabled) => enabled), hasLength(1));
      expect(sentNames(), ['app_open', 'early']);
    });

    test('optOut wipes native reports and the choice survives a restart',
        () async {
      await start();
      Corlex.optOut();
      await pumpEventQueue();
      expect(platform.state.raw, contains('"sdkChoice":"denied"'));
      expect(platform.state.rows, isEmpty);
      Corlex.track('after');
      await Corlex.flush();
      expect(http.requests, isEmpty);

      Corlex.debugReset();
      await start();
      expect(Corlex.consent, ConsentState.denied);
    });

    test(
        'att: notDetermined stays silent, then the answer given later takes effect on return',
        () async {
      platform.tracking = 'notDetermined';
      await start(const CorlexOptions(consent: StartConsent.att));
      expect(Corlex.consent, ConsentState.pending);
      Corlex.track('waiting');
      await Corlex.flush();
      expect(http.requests, isEmpty);

      platform.tracking =
          'authorized'; // the app showed the prompt, the person agreed
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await pumpEventQueue();
      expect(Corlex.consent, ConsentState.granted);
      await Corlex.flush();
      expect(sentNames(), isNot(contains('waiting')));
      Corlex.track('after_permission_restore');
      await Corlex.flush();
      expect(sentNames(), contains('after_permission_restore'));
    });

    test(
        'att: authorized starts granted, denied and restricted start denied (silent)',
        () async {
      platform.tracking = 'authorized';
      await start(const CorlexOptions(consent: StartConsent.att));
      expect(Corlex.consent, ConsentState.granted);
      Corlex.debugReset();
      dir.deleteSync(recursive: true);
      dir.createSync();

      for (final status in ['denied', 'restricted']) {
        platform.tracking = status;
        http.requests.clear();
        await start(const CorlexOptions(consent: StartConsent.att));
        expect(Corlex.consent, ConsentState.denied, reason: status);
        Corlex.track('x');
        await Corlex.flush();
        expect(http.requests, isEmpty);
        Corlex.debugReset();
        dir.deleteSync(recursive: true);
        dir.createSync();
      }
    });

    test('att on Android (no status) behaves as granted', () async {
      platform = FakePlatform(info: FakePlatform.androidInfo);
      await start(const CorlexOptions(consent: StartConsent.att));
      expect(Corlex.consent, ConsentState.granted);
    });
  });

  test(
      'Remote Config through the facade: flag, config, experiment and exposure',
      () async {
    http.replies.add(HttpReply(200,
        etag: '"e"',
        body: jsonEncode({
          'version': 3,
          'etag': '"e"',
          'params': [
            {'k': 'paywall', 't': 'bool', 'v': true, 'r': 10000},
          ],
          'experiments': [
            {
              'k': 'exp_test',
              's': 's',
              'v': [
                {'n': 'control', 'b': 5000, 'v': 'a'},
                {'n': 'variant', 'b': 10000, 'v': 'b'},
              ],
            },
          ],
        })));
    await start(const CorlexOptions(captureLifecycle: false));
    await Corlex.config.ready();
    expect(Corlex.flag('paywall', false), isTrue);
    expect(Corlex.config.get('paywall', false), isTrue);
    expect(Corlex.config.getAll(), {'paywall': true});
    final assigned = Corlex.experiment('exp_test')!.variant;
    expect(assigned, anyOf('control', 'variant'));
    await Corlex.flush();
    final exposure = http.batches.single.events.single;
    expect(exposure['name'], 'corlex.exposure');
    expect(exposure['properties'], containsPair('variant', assigned));
  });
}
