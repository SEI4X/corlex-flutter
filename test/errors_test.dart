import 'dart:ui' as ui;

import 'package:corlex_flutter/src/crash/dart_errors.dart';
import 'package:corlex_flutter/src/crash/dart_stack.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';

import 'support.dart';

const String sampleTrace = '''
#0      _MyState._explode (package:shop/src/checkout.dart:42:7)
#1      _MyState.build.<anonymous closure> (package:shop/src/checkout.dart:30:21)
#2      State.setState (package:flutter/src/widgets/framework.dart:1234:9)
#3      _rootRunUnary (dart:async/zone.dart:1399:13)
#4      main (file:///Users/jane.doe/work/shop/lib/main.dart:12:3)
#5      Future.wait (dart:async/future.dart)
<asynchronous suspension>
#6      new Widget (https://example.com/app.js?token=abc:1:2)
''';

void main() {
  group('parseDartStack', () {
    test('reads {fn, file, line, col} and skips what is not a frame', () {
      final frames = parseDartStack(sampleTrace);
      expect(frames.first, {
        'fn': '_MyState._explode',
        'file': 'package:shop/src/checkout.dart',
        'line': 42,
        'col': 7,
      });
      expect(frames[2]['file'], 'package:flutter/src/widgets/framework.dart');
      expect(frames[3]['file'], 'dart:async/zone.dart');
      expect(frames.length, 7);
    });

    test('a file: URL loses the build machine\'s directories, a query is cut',
        () {
      final frames = parseDartStack(sampleTrace);
      expect(frames[4]['file'], 'main.dart');
      expect(
          frames[5], {'fn': 'Future.wait', 'file': 'dart:async/future.dart'});
      expect(frames[6]['file'], 'app.js');
      expect(sampleTrace.contains('jane.doe'), isTrue);
      expect(frames.toString(), isNot(contains('jane.doe')));
    });

    test('an obfuscated trace has no readable frames (documented follow-up)',
        () {
      const obfuscated = '''
*** *** *** *** *** *** *** *** *** *** *** *** *** *** *** ***
pid: 1, tid: 2, name 1.ui
os: ios arch: arm64 comp: no sim: no
isolate_dso_base: 1000, vm_dso_base: 1000
    #00 abs 000000100a1b2c4 virt 000000000a1b2c4 _kDartIsolateSnapshotInstructions+0x1234
''';
      expect(parseDartStack(obfuscated), isEmpty);
      expect(parseDartStack(null), isEmpty);
    });

    test('at most 100 frames', () {
      final trace =
          List.generate(150, (i) => '#$i  f$i (package:a/a.dart:$i:1)')
              .join('\n');
      expect(parseDartStack(trace).length, 100);
    });
  });

  test(
      'scrubMessage drops URL queries and home directories and cuts at 512 bytes',
      () {
    expect(
      scrubMessage(
          'GET https://api.example.com/user?email=a@b.c&token=xyz failed'),
      'GET https://api.example.com/user failed',
    );
    expect(scrubMessage('cannot open /Users/jane/Documents/x.db'),
        'cannot open ~/Documents/x.db');
    expect(scrubMessage('é' * 600).length, 256);
  });

  group('DartErrorCapture', () {
    late Harness h;
    late DartErrorCapture capture;
    late DateTime now;
    FlutterExceptionHandler? savedFlutter;
    ui.ErrorCallback? savedPlatform;

    setUp(() {
      savedFlutter = FlutterError.onError;
      savedPlatform = ui.PlatformDispatcher.instance.onError;
      now = DateTime.utc(2026, 10, 30, 12);
      h = Harness();
      capture = DartErrorCapture(h.client, now: () => now);
    });
    tearDown(() {
      capture.uninstall();
      FlutterError.onError = savedFlutter;
      ui.PlatformDispatcher.instance.onError = savedPlatform;
      h.dispose();
    });

    Map<String, Object?> props(int index) =>
        (h.saved[index]['properties']! as Map).cast();

    test(
        'an error becomes a non-fatal corlex.crash in the JS shape, event_id = crash_id',
        () {
      capture.record(
          StateError('bad state'), StackTrace.fromString(sampleTrace),
          source: 'global_handler');
      final event = h.saved.single;
      expect(event['name'], 'corlex.crash');
      final p = props(0);
      expect(p['kind'], 'js');
      expect(p['runtime'], 'dart');
      expect(p['fatal'], false);
      expect(p['name'], 'StateError');
      expect(p['message'], 'Error details omitted');
      expect(p['source'], 'global_handler');
      expect(p['symbolicated'], false);
      expect((p['frames']! as List).first,
          containsPair('fn', '_MyState._explode'));
      expect(event['event_id'], p['crash_id']);
      expect(p['build'], '77');
    });

    test(
        'FlutterError.onError and PlatformDispatcher.onError are captured and chained',
        () {
      var flutterSeen = 0;
      var platformSeen = 0;
      FlutterError.onError = (_) => flutterSeen++;
      ui.PlatformDispatcher.instance.onError = (e, s) {
        platformSeen++;
        return true;
      };
      capture.install();
      capture.install(); // idempotent

      FlutterError.onError!(FlutterErrorDetails(
        exception: ArgumentError('widget broke'),
        stack: StackTrace.fromString(sampleTrace),
      ));
      final handled = ui.PlatformDispatcher.instance.onError!(
        const FormatException('async broke'),
        StackTrace.fromString(sampleTrace),
      );

      expect(flutterSeen, 1);
      expect(platformSeen, 1);
      expect(handled, isTrue, reason: 'the previous handler decides');
      expect(h.saved.length, 2);
      expect(props(0)['source'], 'global_handler');
      expect(props(1)['source'], 'unhandled_rejection');
      expect(props(1)['name'], 'FormatException');
    });

    test(
        'without a previous platform handler the error is reported as not handled',
        () {
      ui.PlatformDispatcher.instance.onError = null;
      capture.install();
      expect(
          ui.PlatformDispatcher.instance.onError!(
              StateError('x'), StackTrace.empty),
          isFalse);
    });

    test('uninstall puts the previous handlers back', () {
      void previous(FlutterErrorDetails d) {}
      FlutterError.onError = previous;
      capture.install();
      expect(FlutterError.onError, isNot(same(previous)));
      capture.uninstall();
      expect(FlutterError.onError, same(previous));
    });

    test('the same error is sent once; 5 a minute; 20 a launch', () {
      for (var i = 0; i < 3; i++) {
        capture.record(StateError('same'), StackTrace.fromString(sampleTrace),
            source: 'global_handler');
      }
      expect(h.saved.length, 1);

      for (var i = 0; i < 10; i++) {
        capture.record(StateError('x'),
            StackTrace.fromString('#0 f$i (package:a/a.dart:$i:1)'),
            source: 'global_handler');
      }
      expect(h.saved.length, 5, reason: '1 + 4 more fill the minute');

      now = now.add(const Duration(minutes: 2));
      for (var i = 10; i < 60; i++) {
        capture.record(StateError('x'),
            StackTrace.fromString('#0 f$i (package:a/a.dart:$i:1)'),
            source: 'global_handler');
        if (i % 4 == 0) now = now.add(const Duration(minutes: 2));
      }
      expect(h.saved.length, 20);
    });

    test('a failing toString does not break the reporter', () {
      capture.record(_Hostile(), StackTrace.empty, source: 'global_handler');
      expect(props(0)['message'], 'Error details omitted');
    });

    test('without consent nothing is recorded', () {
      h.client.optOut();
      capture.record(StateError('x'), StackTrace.empty,
          source: 'global_handler');
      expect(h.http.requests, isEmpty);
      expect(h.saved, isEmpty);
    });
  });
}

class _Hostile {
  @override
  String toString() => throw StateError('no');
}
