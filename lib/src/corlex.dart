import 'dart:async';
import 'dart:io';

import 'package:flutter/widgets.dart';

import 'client.dart';
import 'config/remote_config.dart';
import 'crash/dart_errors.dart';
import 'crash/native_crash.dart';
import 'http.dart';
import 'lifecycle.dart';
import 'options.dart';
import 'platform.dart';
import 'screens.dart';
import 'endpoint_policy.dart';
import 'binding/driver.dart';
import 'binding/bridge.dart';
import 'binding/digest.dart';
import 'binding/http.dart';
import 'binding/legacy.dart';

part 'startup.dart';

/// Remote Config (SPEC section 10): values the project sets in the Corlex screen, evaluated on the
/// device. Before `Corlex.start` finished, without consent or without a download every read returns
/// the fallback.
class ConfigApi {
  ConfigApi._();

  RemoteConfig? get _remote => Corlex._client?.currentRemote;

  /// The value for this person, or [fallback] when the parameter does not exist, the rollout does
  /// not reach them, the value is of another type than [fallback] or the config is not available.
  T get<T extends Object>(String key, T fallback) =>
      _remote?.get<T>(key, fallback) ?? fallback;

  /// Every parameter that applies to this person, by key.
  Map<String, Object?> getAll() => _remote?.getAll() ?? {};

  /// Called when a newer config was downloaded; returns the function that stops listening.
  void Function() onUpdate(void Function(ConfigUpdate update) listener) =>
      _remote?.onUpdate(listener) ?? () {};

  /// Completes when this launch's download finished or after `configTimeout`. Await it before the
  /// first read to see a config published since the last launch.
  Future<void> ready() => _remote?.ready() ?? Future.value();

  /// Downloads now (one request, shared by concurrent calls).
  Future<void> refresh() => _remote?.refresh() ?? Future.value();
}

/// The Corlex SDK. `await Corlex.start('ck_live_...')` once, before `runApp`.
///
/// Every call before `start` finishes, or after a denied consent, does nothing.
abstract final class Corlex {
  static CorlexClient? _client;
  static DartErrorCapture? _errors;
  static LifecycleTracker? _lifecycle;
  static ScreenTracker? _screens;

  /// Remote Config: `Corlex.config.get('free_trial_days', 7)`.
  static final ConfigApi config = ConfigApi._();

  /// Starts the SDK. Reads device facts from the platform, restores the queue and identity, starts
  /// Remote Config and the automatic events, installs the error handlers and sends the native
  /// crashes of the last launch. Calling it again does nothing.
  ///
  /// [platform], [http] and [directory] are for the SDK's own tests.
  static Future<void> start(
    String key, {
    CorlexOptions options = const CorlexOptions(),
    @visibleForTesting CorlexPlatform? platform,
    @visibleForTesting Http? http,
    @visibleForTesting Directory? directory,
  }) async {
    if (_client != null || _Startup.starting) return;
    if (key.length != 51 ||
        !RegExp(r'^ck_(live|test)_[0-9A-Za-z]{43}$').hasMatch(key)) {
      debugPrint('[corlex] invalid_sdk_key');
      return;
    }
    if (!EndpointPolicy.allowed(options.endpoint, options.allowInsecureHttp) ||
        !EndpointPolicy.allowed(
            options.configEndpoint, options.allowInsecureHttp)) {
      debugPrint('[corlex] invalid_endpoint');
      return;
    }
    final ticket = _Startup.reserve();
    try {
      await _Startup.run(ticket, key,
          options: options,
          native: platform ?? MethodChannelPlatform(),
          http: http,
          directory: directory);
    } on Object {
      if (_Startup.current(ticket)) {
        debugReset();
        debugPrint('[corlex] startup_failed');
      }
    } finally {
      _Startup.finish(ticket);
    }
  }

  /// Sends an event. `name`: 1-128 chars of `[a-z0-9_.:-]`; `corlex.` is reserved.
  static void track(String name, [Map<String, Object?>? properties]) =>
      _client?.track(name, properties);

  /// Links the events to a user. `traits` are merged into the profile.
  static void identify(String userId, [Map<String, Object?>? traits]) =>
      _client?.identify(userId, traits);

  static void setUserProperties(Map<String, Object?> properties) =>
      _client?.setUserProperties(properties);

  /// A manual `screen_view`. [name] is a route pattern (`/user/:id`), not a concrete path.
  static void screen(String name, {String source = 'manual'}) =>
      _screens?.view(name, source: source);

  /// Shorthand for `config.get(key, defaultValue)` with a scalar default.
  static T flag<T extends Object>(String key, T defaultValue) =>
      config.get(key, defaultValue);

  /// The person's variant in a running A/B test, or null (not running, not downloaded, no consent).
  /// Reading it sends one `corlex.exposure` per person and test per launch.
  static ExperimentAssignment? experiment(String key) =>
      _client?.currentRemote?.experiment(key);

  /// Reports an error you caught yourself (`runZonedGuarded`, `try`/`catch`) as `corlex.crash`.
  static void recordError(Object error, StackTrace? stack,
          {bool fatal = false}) =>
      _errors?.record(error, stack, source: 'global_handler', fatal: fatal);

  /// Logout: a new anonymous person.
  static void reset() => _client?.reset();

  /// Sends what is queued now; completes when the queue is empty or delivery failed.
  static Future<void> flush() => _client?.flush() ?? Future.value();

  /// Where consent stands.
  static ConsentState get consent => _client?.consent ?? ConsentState.pending;

  static void optIn() => _Startup.choose(ConsentState.granted);

  /// Stops collecting and removes everything the SDK stored on the device.
  static void optOut() => _Startup.choose(ConsentState.denied);

  /// For the SDK's own tests: detaches handlers and forgets the instance.
  @visibleForTesting
  static void debugReset() {
    _Startup.reset();
    _errors?.uninstall();
    _lifecycle?.stop();
    _client?.dispose();
    _client = null;
    _errors = null;
    _lifecycle = null;
    _screens = null;
  }
}
