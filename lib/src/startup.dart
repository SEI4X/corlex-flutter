part of 'corlex.dart';

/// One async startup lifetime. Every continuation belongs to its originating client/choice.
abstract final class _Startup {
  static int _epoch = 0, _revision = 0;
  static bool starting = false, _resolving = false;
  static ConsentState? _choice;
  static BindingDriver? _binding;

  static int reserve() {
    starting = _resolving = true;
    _choice = null;
    return ++_epoch;
  }

  static bool current(int ticket) => ticket == _epoch;
  static bool active(int ticket, CorlexClient client) =>
      current(ticket) && identical(Corlex._client, client);
  static void finish(int ticket) {
    if (current(ticket)) starting = _resolving = false;
  }

  static void reset() {
    ++_epoch;
    ++_revision;
    starting = _resolving = false;
    _choice = null;
    _binding?.close();
    _binding = null;
  }

  static void choose(ConsentState state) {
    ++_revision;
    if (_resolving) {
      _choice = state;
      if (state == ConsentState.denied) Corlex._client?.optOut();
      return;
    }
    if (state == ConsentState.granted) {
      Corlex._client?.optIn();
    } else {
      Corlex._client?.optOut();
    }
  }

  static Future<void> run(int ticket, String key,
      {required CorlexOptions options,
      required CorlexPlatform native,
      Http? http,
      Directory? directory}) async {
    WidgetsFlutterBinding.ensureInitialized();
    final device = await native.deviceInfo();
    if (!current(ticket)) return;
    final dir = directory ?? Directory('${device.supportDir}/corlex');
    final bridge = native is StateBridgeProvider
        ? await (native as StateBridgeProvider).stateBridge()
        : null;
    if (!current(ticket)) return;
    final owner = bindingDigest(key,
        endpoint: options.endpoint,
        configEndpoint: options.configEndpoint,
        allowInsecureHttp: options.allowInsecureHttp);
    if (owner == null) return;
    final binding = BindingDriver(owner, bridge,
        readCeiling: options.consent == StartConsent.att
            ? () async => fromTracking(await native.trackingStatus())
            : null);
    _binding = binding;
    final initial = await binding.prepare(_choice ??
        legacyConsent(dir) ??
        (options.consent == StartConsent.pending
            ? ConsentState.pending
            : ConsentState.granted));
    if (!current(ticket)) {
      binding.close();
      return;
    }
    final client = CorlexClient(
        key: key,
        options: options,
        device: device,
        http: BoundHttp(http ?? IoHttp(), binding),
        directory: dir,
        store: binding,
        binding: binding);
    Corlex._client = client;
    _resolving = false;
    if (bridge?.current()?.isNotEmpty == true) discardLegacy(dir);
    client.start(_choice ?? initial);
    if (_choice == ConsentState.denied) client.optOut();
    if (_choice == ConsentState.granted) client.optIn();
    client.onConsentChanged =
        (state) => unawaited(consentChanged(ticket, client, native, state));
    Corlex._screens = ScreenTracker(client);
    await wireCrashes(ticket, client, native);
    if (!active(ticket, client)) return;
    if ((options.captureLifecycle && client.started) ||
        options.consent == StartConsent.att) {
      Corlex._lifecycle = LifecycleTracker(client,
          captureEvents: options.captureLifecycle,
          onForeground: () =>
              unawaited(refreshTracking(ticket, client, native)))
        ..start();
    }
  }

  static ConsentState fromTracking(String? status) => switch (status) {
        'authorized' || null => ConsentState.granted,
        'denied' || 'restricted' => ConsentState.denied,
        _ => ConsentState.pending,
      };

  static Future<void> refreshTracking(
      int ticket, CorlexClient client, CorlexPlatform native) async {
    final revision = _revision;
    if (!active(ticket, client) || client.options.consent != StartConsent.att) {
      return;
    }
    try {
      await client.refreshBindingCeiling();
      if (!active(ticket, client) || revision != _revision) return;
    } on Object {
      client.log('tracking_status_unavailable');
    }
  }

  static Future<void> wireCrashes(
      int ticket, CorlexClient client, CorlexPlatform native) async {
    if (!active(ticket, client) || !client.options.captureErrors) return;
    Corlex._errors = DartErrorCapture(client)..install();
    final revision = _revision;
    try {
      final selected = client.binding;
      if (selected != null && !await selected.select()) return;
      final scope = selected?.generation == null
          ? null
          : CrashScope(selected!.owner, selected.generation!,
              captureErrorMessages: client.options.captureErrorMessages);
      await native.setCrashCapture(
          enabled: client.consent == ConsentState.granted, scope: scope);
      if (active(ticket, client) &&
          revision == _revision &&
          client.consent == ConsentState.granted) {
        await sendPendingCrashes(client, native,
            isCurrent: () => active(ticket, client) && revision == _revision);
      }
    } on Object {
      client.log('native_crash_reporter_unavailable');
    }
  }

  static Future<void> consentChanged(int ticket, CorlexClient client,
      CorlexPlatform native, ConsentState state) async {
    if (!active(ticket, client) || !client.options.captureErrors) return;
    final revision = _revision;
    try {
      final selected = client.binding;
      if (selected != null &&
          (state != ConsentState.granted || !await selected.select())) {
        return;
      }
      final scope = selected?.generation == null
          ? null
          : CrashScope(selected!.owner, selected.generation!,
              captureErrorMessages: client.options.captureErrorMessages);
      await native.setCrashCapture(
          enabled: state == ConsentState.granted,
          wipe: state == ConsentState.denied,
          scope: scope);
      if (active(ticket, client) &&
          revision == _revision &&
          client.consent == ConsentState.granted &&
          state == ConsentState.granted) {
        await sendPendingCrashes(client, native,
            isCurrent: () => active(ticket, client) && revision == _revision);
      }
    } on Object {
      client.log('native_crash_reporter_unavailable');
    }
  }
}
