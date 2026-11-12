import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:ui' as ui;

import 'config/exposure.dart';
import 'config/remote_config.dart';
import 'http.dart';
import 'identity.dart';
import 'limits.dart';
import 'options.dart';
import 'platform.dart';
import 'properties.dart';
import 'queue.dart';
import 'sender.dart';
import 'storage.dart';
import 'version.dart';
import 'binding/driver.dart';
import 'release.dart';
part 'client_binding.dart';
part 'client_event.dart';

const String _consentKey = 'corlex_consent';

/// What an event that happened earlier keeps when it is recorded late (a crash found at the next
/// launch): its time, its id and the app it happened in.
class CaptureMeta {
  const CaptureMeta({
    this.timestamp,
    this.eventId,
    this.appVersion,
    this.build,
    this.osVersion,
    this.deviceModel,
  });

  final DateTime? timestamp;
  final String? eventId;
  final String? appVersion;
  final String? build;
  final String? osVersion;
  final String? deviceModel;
}

/// RFC 3339 in UTC with millisecond precision.
String isoTime(DateTime time) =>
    DateTime.fromMillisecondsSinceEpoch(time.millisecondsSinceEpoch,
            isUtc: true)
        .toIso8601String();

/// One SDK instance: events, consent, the queue, delivery, identity and Remote Config. A Dart port
/// of `CorlexCore` from `packages/sdk-core`; the platform specifics come in through [CorlexPlatform].
class CorlexClient {
  CorlexClient({
    required this.key,
    required this.options,
    required this.device,
    required this.http,
    required this.directory,
    required this.store,
    String Function()? locale,
    TimerFactory? timer,
    this.binding,
  })  : _locale = locale ??
            (() => ui.PlatformDispatcher.instance.locale.toLanguageTag()),
        _timer = timer {
    binding?.onInvalidate = _invalidateBinding;
  }

  final BindingDriver? binding;
  Future<void>? _bindingGrant, _bindingFlush;
  final _bindingJobs = <void Function()>[];
  final String key;
  final CorlexOptions options;
  final DeviceInfo device;
  final Http http;
  final Directory directory;
  final KeyValueStore store;
  final String Function() _locale;
  final TimerFactory? _timer;

  ConsentState _consent = ConsentState.pending;
  ConsentState get consent {
    _bindingFence();
    return _consent;
  }

  set consent(ConsentState state) {
    _consent = state;
  }

  Future<void> refreshBindingCeiling() => _refreshBindingCeiling();
  RemoteConfig? get currentRemote {
    _bindingFence();
    return remote;
  }

  bool _disposed = false;

  /// Told when consent changes after start (the facade turns native crash capture on or off).
  void Function(ConsentState state)? onConsentChanged;

  EventQueue? _queue;
  Sender? _sender;
  Identity? _identity;
  RemoteConfig? remote;
  final Exposures _exposures = Exposures();
  bool _warnedName = false;

  File get _queueFile => File('${directory.path}/queue.jsonl');

  bool get started => _queue != null;

  void log(String message) {
    if (options.debug) {
      // ignore: avoid_print
      print('[corlex] $message');
    }
  }

  /// Starts with [initial] consent (already resolved from the stored choice and the options).
  void start(ConsentState initial) {
    if (_disposed) return;
    consent = initial;
    if (consent != ConsentState.granted) pauseHttp(http);
    if (consent == ConsentState.denied) return;
    if (consent == ConsentState.granted) resumeHttp(http);
    final granted = consent == ConsentState.granted;
    final queue = EventQueue(binding == null && granted ? _queueFile : null,
        store: binding != null && granted ? store : null);
    _queue = queue;
    _identity = Identity(store, persisted: granted);
    _sender = Sender(
      queue: queue,
      http: http,
      endpoint: options.endpoint.replaceAll(RegExp(r'/+$'), ''),
      key: key,
      batchSize: options.batchSize.clamp(1, maxBatchEvents),
      flushInterval: options.flushInterval,
      log: log,
      timer: _timer,
    );
    remote = _createRemoteConfig();
    if (granted) {
      _sender!.schedule();
      _startRemoteConfig();
    }
  }

  RemoteConfig _createRemoteConfig() => RemoteConfig(
        store: store,
        http: http,
        platforms: ['flutter', device.platform],
        endpoint: options.configEndpoint.replaceAll(RegExp(r'/+$'), ''),
        key: key,
        live: options.configLive,
        timeout: options.configTimeout,
        idOf: _personId,
        expose: _expose,
        log: log,
      );

  String? _personId() => _identity?.userId ?? _identity?.anonymousId;

  /// Config is downloaded only with consent: the SDK makes no request without it (SPEC 12.1).
  void _startRemoteConfig() {
    if (options.configEnabled) remote?.start();
  }

  void _expose(String experiment, String variant) {
    final id = _personId();
    if (id == null || !_exposures.first(experiment, id)) return;
    track(eventExposure, {'experiment': experiment, 'variant': variant});
  }

  void track(String name, [Map<String, Object?>? properties]) =>
      capture(name, properties, const CaptureMeta());

  /// `track()` for an event that already happened. An id already in the queue is not queued twice.
  void capture(
      String name, Map<String, Object?>? properties, CaptureMeta meta) {
    if (_deferBound(() => capture(name, properties, meta))) return;
    final queue = _queue;
    if (_disposed || queue == null || consent == ConsentState.denied) return;
    if (!namePattern.hasMatch(name)) return _rejectName();
    final event = _buildEvent(name, properties, meta);
    if (queue.has(event['event_id']! as String)) return;
    if (byteLength(jsonEncode(event)) > maxEventBytes) {
      log('event_too_large');
      return;
    }
    queue.push(event);
    if (consent == ConsentState.granted) _sender!.schedule();
  }

  void _rejectName() {
    if (_warnedName) return;
    _warnedName = true;
    log('invalid_event_name');
  }

  void identify(String userId, [Map<String, Object?>? traits]) {
    if (_deferBound(() => identify(userId, traits))) return;
    if (!started || consent == ConsentState.denied || userId.isEmpty) return;
    _identity!.setUser(userId);
    track(eventIdentify, traits);
  }

  void setUserProperties(Map<String, Object?> properties) =>
      track(eventUserProps, properties);

  void reset() {
    _bindingFence();
    _exposures.clear();
    _identity?.reset();
  }

  Future<void> flush() {
    if (binding != null) return _flushBinding();
    final sender = _sender;
    return sender != null && consent == ConsentState.granted
        ? sender.flush()
        : Future.value();
  }

  void optIn() {
    if (binding != null) {
      _grantBound();
      return;
    }
    consent = ConsentState.granted;
    store.set(_consentKey, 'granted');
    resumeHttp(http);
    final queue = _queue;
    if (queue == null) {
      start(ConsentState.granted);
    } else {
      _identity!.persist();
      queue.enablePersistence(_queueFile);
      _sender!.resume();
      _startRemoteConfig();
    }
    onConsentChanged?.call(consent);
  }

  /// Stops collecting and removes everything the SDK stored on this device, the saved config too.
  void optOut() {
    if (binding != null) {
      binding!.deny();
      _bindingJobs.clear();
      _invalidateBinding();
      return;
    }
    consent = ConsentState.denied;
    store.set(_consentKey, 'denied');
    remote?.stop(wipe: true);
    _exposures.clear();
    _sender?.stop();
    pauseHttp(http);
    _queue?.clear();
    _identity?.wipe();
    _identity = Identity(store, persisted: false);
    onConsentChanged?.call(consent);
  }

  /// The choice saved by `optIn()` / `optOut()`, if any.
  ConsentState? get storedConsent => switch (store.get(_consentKey)) {
        'granted' => ConsentState.granted,
        'denied' => ConsentState.denied,
        _ => null,
      };

  void dispose() {
    _disposed = true;
    binding?.close();
    remote?.destroy();
    _sender?.dispose();
    pauseHttp(http);
  }
}
