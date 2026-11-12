import 'dart:async';

import 'package:corlex_flutter/corlex_flutter.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// The example's own channel (ios/Runner/AppDelegate.swift, MainActivity.kt): it throws a native
/// exception, which the Corlex plugin's native crash reporter writes down for the next launch.
const MethodChannel _native = MethodChannel('example/crash');

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  int _taps = 0;
  String _status = 'Ready';

  void _say(String text) => setState(() => _status = text);

  Future<void> _nativeCrash(String kind) async {
    _say('Crashing natively...');
    try {
      await _native.invokeMethod<void>('crash', kind);
    } on MissingPluginException {
      _say('Not available on this platform');
    }
  }

  @override
  Widget build(BuildContext context) {
    final checkout = Corlex.flag('show_new_checkout', false);
    final banner = Corlex.config.get('welcome_banner', '(default)');
    final variant = Corlex.experiment('onboarding_test')?.variant ?? 'none';
    return Scaffold(
      appBar: AppBar(title: const Text('Corlex Flutter')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Text(_status, key: const Key('status')),
          Text('banner: $banner', key: const Key('banner')),
          Text('flag show_new_checkout = $checkout, experiment = $variant'),
          const SizedBox(height: 8),
          _button('Track event', () {
            _taps++;
            Corlex.track('example_tap', {'taps': _taps});
            _say('example_tap sent ($_taps)');
          }),
          _button('Identify', () {
            Corlex.identify('example_user', {'plan': 'free'});
            Corlex.setUserProperties({'tier': 'demo'});
            _say('identify + user properties');
          }),
          _button('Open product 42', () {
            Navigator.of(context).pushNamed('/product/:id', arguments: 42);
          }),
          _button(
              'Settings', () => Navigator.of(context).pushNamed('/settings')),
          _button('Flush', () async {
            await Corlex.flush();
            _say('flushed');
          }),
          const Divider(),
          _button('Dart error (async)', () {
            Future<void>.delayed(
                Duration.zero, () => throw StateError('Example async error'));
          }),
          _button('Dart error (Flutter framework)', () {
            FlutterError.reportError(FlutterErrorDetails(
              exception: ArgumentError('Example framework error'),
              stack: StackTrace.current,
              library: 'example',
            ));
          }),
          _button('Native crash (exception)', () => _nativeCrash('exception')),
          _button('Native crash (signal, iOS)', () => _nativeCrash('signal')),
        ],
      ),
    );
  }

  Widget _button(String label, FutureOr<void> Function() onPressed) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: FilledButton(onPressed: onPressed, child: Text(label)),
      );
}

class ProductPage extends StatelessWidget {
  const ProductPage({required this.id, super.key});

  final int id;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text('Product $id')),
      body: Center(
        child: FilledButton(
          onPressed: () => Corlex.track('add_to_cart', {'product': id}),
          child: const Text('Add to cart'),
        ),
      ),
    );
  }
}

class SettingsPage extends StatefulWidget {
  const SettingsPage({super.key});

  @override
  State<SettingsPage> createState() => _SettingsPageState();
}

class _SettingsPageState extends State<SettingsPage> {
  @override
  Widget build(BuildContext context) {
    final granted = Corlex.consent == ConsentState.granted;
    return Scaffold(
      appBar: AppBar(title: const Text('Settings')),
      body: ListView(children: [
        SwitchListTile(
          title: const Text('Share usage data'),
          subtitle: Text('Consent: ${Corlex.consent.name}'),
          value: granted,
          onChanged: (on) => setState(on ? Corlex.optIn : Corlex.optOut),
        ),
        ListTile(
          title: const Text('Log out'),
          subtitle: const Text('Starts a new anonymous person'),
          onTap: Corlex.reset,
        ),
      ]),
    );
  }
}
