import 'dart:async';

import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:flutter/material.dart';

import 'pages.dart';
import 'scenario.dart';

/// Where the events go. The example reads them from `--dart-define`, so no key lives in the code:
///
///     flutter run --dart-define=CORLEX_KEY=ck_test_... --dart-define=CORLEX_ENDPOINT=http://10.0.2.2:18950
///
/// 10.0.2.2 is the Android emulator's name for the host machine; the iOS simulator uses 127.0.0.1.
const String corlexKey = String.fromEnvironment(
  'CORLEX_KEY',
  defaultValue: 'ck_test_0000000000000000000000000000000000000000000',
);
const String corlexEndpoint = String.fromEnvironment(
  'CORLEX_ENDPOINT',
  defaultValue: 'https://ingest.corlex.ru',
);
const String corlexConfigEndpoint = String.fromEnvironment(
  'CORLEX_CONFIG_ENDPOINT',
  defaultValue: 'https://config.corlex.ru',
);

Future<void> main() async {
  // runZonedGuarded is not needed: the SDK listens to FlutterError.onError and
  // PlatformDispatcher.onError. Use it (with Corlex.recordError) only to catch errors of your own zone.
  await Corlex.start(
    corlexKey,
    options: const CorlexOptions(
      endpoint: corlexEndpoint,
      configEndpoint: corlexConfigEndpoint,
      flushInterval: Duration(seconds: 2),
      debug: true,
    ),
  );
  runApp(const ExampleApp());
  unawaited(runScenario(navigatorKey));
}

final GlobalKey<NavigatorState> navigatorKey = GlobalKey<NavigatorState>();

class ExampleApp extends StatelessWidget {
  const ExampleApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Corlex Flutter',
      theme: ThemeData(colorSchemeSeed: Colors.indigo, useMaterial3: true),
      // Screens are named by route: this is all `screen_view` reads.
      navigatorKey: navigatorKey,
      navigatorObservers: [CorlexNavigatorObserver()],
      initialRoute: '/',
      onGenerateRoute: (settings) {
        final page = switch (settings.name) {
          '/' => const HomePage(),
          '/product/:id' => ProductPage(id: settings.arguments as int? ?? 0),
          '/settings' => const SettingsPage(),
          _ => const HomePage(),
        };
        return MaterialPageRoute<void>(
            settings: settings, builder: (_) => page);
      },
    );
  }
}
