import 'dart:async';
import 'dart:convert';

import '../http.dart';
import '../storage.dart';
import 'evaluator.dart';
import 'document.dart';
import 'bounded_json.dart';

/// Where the last document lives between launches. It holds no personal data.
const String configKey = 'corlex_cfg';

/// A newer config was downloaded. `applied: false`: it is saved and takes effect at the next launch.
class ConfigUpdate {
  const ConfigUpdate({required this.version, required this.applied});

  final int version;
  final bool applied;
}

/// The variant a person got in a running A/B test.
class ExperimentAssignment {
  const ExperimentAssignment(this.variant, this.value);

  final String variant;
  final Object? value;
}

String _kindOf(Object? v) => v is List
    ? 'array'
    : v == null
        ? 'null'
        : v is Map
            ? 'object'
            : v is num
                ? 'number'
                : v is bool
                    ? 'boolean'
                    : 'string';

/// The project's published config on this device (SPEC section 10, docs/remote-config.md).
///
/// The document is downloaded once per launch (a conditional GET, usually a 304), kept in the store
/// and evaluated HERE with the same stable bucketing as the server and the other SDKs, so no request
/// names a person. A value must not flip while the app runs: a new document applies at once only if
/// nothing was read yet in this launch (or `live` is on); otherwise it waits for the next launch.
class RemoteConfig {
  RemoteConfig({
    required this.store,
    required this.http,
    required this.platforms,
    required this.endpoint,
    required this.key,
    required this.live,
    required this.timeout,
    required this.idOf,
    required this.expose,
    required this.log,
  });

  final KeyValueStore store;
  final Http http;

  /// Platform names tried for an override, most specific first (`flutter`, then `ios`/`android`).
  final List<String> platforms;
  final String endpoint;
  final String key;
  final bool live;
  final Duration timeout;

  /// The user id after identify(), otherwise the anonymous id: what the rollout buckets on.
  final String? Function() idOf;
  final void Function(String experiment, String variant) expose;
  final void Function(String) log;

  Map<String, Object?>? _active;
  String? _etag;
  bool _started = false;
  int _generation = 0;
  bool _handedOut = false;
  Future<void>? _inflight;
  Timer? _timer;
  final Set<void Function(ConfigUpdate)> _listeners = {};

  List<Object?> get _params =>
      (_active?['params'] as List<Object?>?) ?? const [];

  List<Map<String, Object?>> get _experiments =>
      ((_active?['experiments'] as List<Object?>?) ?? const [])
          .cast<Map<String, Object?>>();

  /// Reads the saved document and downloads the current one. Needs consent: the caller checks.
  void start() {
    if (_started) return;
    _started = true;
    _generation++;
    _load();
    _timer = Timer(Duration.zero, () => unawaited(refresh()));
  }

  /// Stops downloads; [wipe] also forgets the saved document (opt-out).
  void stop({bool wipe = false}) {
    _started = false;
    _generation++;
    _inflight = null;
    _timer?.cancel();
    if (wipe) {
      store.remove(configKey);
      _active = null;
      _etag = null;
    }
  }

  void destroy() {
    stop();
    _listeners.clear();
  }

  /// The variant of a running experiment for this person, or null. Reading it IS the exposure.
  ExperimentAssignment? experiment(String key) {
    _handedOut = true;
    final id = idOf();
    final match = _experiments.where((e) => e['k'] == key);
    if (match.isEmpty || id == null) return null;
    final assigned = assignVariant(match.first, id);
    if (assigned == null) return null;
    expose(key, assigned.variant);
    return ExperimentAssignment(assigned.variant, assigned.value);
  }

  /// The value for this person, or [fallback] when the parameter does not exist, the rollout does
  /// not reach them, the type differs from [fallback] or the config is not available. Never throws.
  T get<T extends Object>(String key, T fallback) {
    _handedOut = true;
    final id = idOf();
    if (id == null) return fallback;
    final linked = _experiments.where((e) => e['p'] == key);
    final assigned = linked.isEmpty ? null : assignVariant(linked.first, id);
    if (assigned != null) {
      if (_kindOf(assigned.value) != _kindOf(fallback)) return fallback;
      expose(linked.first['k'] as String, assigned.variant);
      return _typed<T>(assigned.value, fallback);
    }
    final param =
        _params.whereType<Map<String, Object?>>().where((p) => p['k'] == key);
    if (param.isEmpty) return fallback;
    final resolved = resolveParam(param.first, id, platforms);
    return resolved == null ? fallback : _typed<T>(resolved.value, fallback);
  }

  T _typed<T extends Object>(Object? value, T fallback) {
    if (_kindOf(value) != _kindOf(fallback)) return fallback;
    if (fallback is double && value is int) return value.toDouble() as T;
    return value is T ? value : fallback;
  }

  Map<String, Object?> getAll() {
    _handedOut = true;
    final id = idOf();
    if (_active == null || id == null) return {};
    final values = resolveAll(_params, id, platforms);
    // Variants of linked parameters are listed, but listing is not an exposure.
    for (final experiment in _experiments) {
      final param = experiment['p'];
      final assigned = param is String ? assignVariant(experiment, id) : null;
      if (param is String && assigned != null) values[param] = assigned.value;
    }
    return values;
  }

  /// Called when a newer config was downloaded; returns the function that stops listening.
  void Function() onUpdate(void Function(ConfigUpdate) listener) {
    _listeners.add(listener);
    return () => _listeners.remove(listener);
  }

  /// Completes when this launch's download finished, or after [timeout], whichever is first.
  Future<void> ready() {
    if (!_started) return Future.value();
    final done = Completer<void>();
    final timer = Timer(timeout, () {
      if (!done.isCompleted) done.complete();
    });
    unawaited(refresh().whenComplete(() {
      timer.cancel();
      if (!done.isCompleted) done.complete();
    }));
    return done.future;
  }

  /// Downloads now. Concurrent calls share one request. Never fails.
  Future<void> refresh() {
    if (!_started) return Future.value();
    _timer?.cancel();
    final generation = _generation;
    return _inflight ??= _download(generation).whenComplete(() {
      if (generation == _generation) _inflight = null;
    });
  }

  void _load() {
    try {
      final saved =
          parseConfigJson(store.get(configKey) ?? 'null', cache: true);
      if (saved is Map &&
          httpTag(saved['etag']) &&
          isConfigDocument(saved['doc']) &&
          saved['etag'] == (saved['doc'] as Map)['etag']) {
        _active = (saved['doc'] as Map).cast<String, Object?>();
        _etag = saved['etag'] as String;
      } else {
        store.remove(configKey);
      }
    } on Object {
      store.remove(configKey);
    }
  }

  Future<Map<String, Object?>?> _fetch() async {
    final headers = {
      'X-Corlex-Key': key,
      if (_etag != null) 'If-None-Match': _etag!
    };
    try {
      final reply =
          await http.get(Uri.parse('$endpoint/v1/config/document'), headers);
      if (reply.status != 200) {
        if (reply.status != 304) {
          log('config: the server answered ${reply.status}');
        }
        return null;
      }
      final doc = parseConfigJson(reply.body);
      return isConfigDocument(doc)
          ? (doc as Map).cast<String, Object?>()
          : null;
    } on Object {
      log('config: could not download');
      return null;
    }
  }

  Future<void> _download(int generation) async {
    final doc = await _fetch();
    if (doc == null || !_started || generation != _generation) return;
    _etag = doc['etag'] as String;
    store.set(configKey, jsonEncode({'etag': _etag, 'doc': doc}));
    if (!_started || generation != _generation) return;
    final apply = live || !_handedOut || _active == null;
    if (apply) _active = doc;
    final version = doc['version'] as int;
    log('config v$version ${apply ? 'applied' : 'saved for the next launch'}');
    for (final listener in List.of(_listeners)) {
      if (!_started || generation != _generation) break;
      try {
        listener(ConfigUpdate(version: version, applied: apply));
      } on Object {
        log('config_listener_error');
      }
    }
  }
}
