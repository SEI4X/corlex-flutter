import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:corlex_flutter/src/screens.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('screenName', () {
    test('cuts query and fragment and replaces ids', () {
      expect(screenName('/home'), '/home');
      expect(screenName('/user/42'), '/user/[id]');
      expect(
        screenName('/order/550e8400-e29b-41d4-a716-446655440000/items'),
        '/order/[id]/items',
      );
      expect(screenName('/p/0123456789abcdef?ref=mail#top'), '/p/[id]');
      expect(screenName('/user/:id'), '/user/:id',
          reason: 'a pattern stays as it is');
      expect(screenName('Settings'), 'Settings');
    });
  });

  group('CorlexNavigatorObserver', () {
    final seen = <String>[];
    late CorlexNavigatorObserver observer;

    Widget app() => MaterialApp(
          navigatorObservers: [observer],
          initialRoute: '/',
          onGenerateRoute: (settings) => MaterialPageRoute<void>(
            settings: settings,
            builder: (context) => Scaffold(
              body: Column(children: [
                Text('page ${settings.name}'),
                TextButton(
                  onPressed: () => Navigator.of(context)
                      .pushNamed('/user/42', arguments: 'secret-argument'),
                  child: const Text('open'),
                ),
                TextButton(
                  onPressed: () => showDialog<void>(
                    context: context,
                    routeSettings: const RouteSettings(name: '/dialog'),
                    builder: (_) => const AlertDialog(title: Text('hi')),
                  ),
                  child: const Text('dialog'),
                ),
              ]),
            ),
          ),
        );

    setUp(() {
      seen.clear();
      observer = CorlexNavigatorObserver(onScreen: seen.add);
    });

    testWidgets(
        'reports page routes by name, never arguments; dialogs are skipped',
        (tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.text('dialog'));
      await tester.pumpAndSettle();
      await tester.tapAt(const Offset(5, 5)); // dismiss
      await tester.pumpAndSettle();
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      expect(seen, ['/', '/user/42']);
      expect(seen.join(), isNot(contains('secret')));
    });

    testWidgets('going back reports the screen you return to', (tester) async {
      await tester.pumpWidget(app());
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pumpAndSettle();
      expect(seen, ['/', '/user/42', '/']);
    });

    testWidgets('a route without a name is not a screen', (tester) async {
      final key = GlobalKey<NavigatorState>();
      await tester.pumpWidget(MaterialApp(
        navigatorKey: key,
        navigatorObservers: [observer],
        home: const Scaffold(body: Text('home')),
      ));
      seen.clear();
      key.currentState!
          .push(MaterialPageRoute<void>(builder: (_) => const Text('anon')));
      await tester.pumpAndSettle();
      expect(seen, isEmpty);
    });

    test('the default observer talks to Corlex.screen (a no-op before start)',
        () {
      expect(() => CorlexNavigatorObserver().onScreen('/x'), returnsNormally);
      expect(Corlex.consent, ConsentState.pending);
    });
  });
}
