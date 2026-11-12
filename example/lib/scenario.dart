import 'dart:async';

import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// `--dart-define=CORLEX_SCENARIO=events|crash` plays what the buttons do, so a run can be checked
/// on a simulator or an emulator without tapping: `events` sends events, opens a screen and raises
/// Dart errors; `crash` and `signal` (iOS) crash natively after a short delay (the next launch sends the report).
const String scenario = String.fromEnvironment('CORLEX_SCENARIO');

Future<void> runScenario(GlobalKey<NavigatorState> navigator) async {
  if (scenario.isEmpty) return;
  await Future<void>.delayed(const Duration(seconds: 2));
  if (scenario == 'events') {
    Corlex.track('example_tap', {'taps': 1});
    Corlex.identify('example_user', {'plan': 'free'});
    unawaited(navigator.currentState?.pushNamed('/product/:id', arguments: 42));
    await Future<void>.delayed(const Duration(seconds: 1));
    Corlex.track('add_to_cart', {'product': 42});
    Future<void>.delayed(
        Duration.zero, () => throw StateError('Example async error'));
    FlutterError.reportError(FlutterErrorDetails(
      exception: ArgumentError('Example framework error'),
      stack: StackTrace.current,
      library: 'example',
    ));
    await Future<void>.delayed(const Duration(seconds: 1));
    navigator.currentState?.pop();
  } else if (scenario == 'crash' || scenario == 'signal') {
    await const MethodChannel('example/crash').invokeMethod<void>(
        'crash', scenario == 'signal' ? 'signal' : 'exception');
  }
}
