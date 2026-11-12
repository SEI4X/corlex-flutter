// Compiled Remote Config boundary, shared with the other SDKs.
const int maxConfigBytes = 1024 * 1024;
const int maxConfigDepth = 16;
const _reserved = {'__proto__', 'prototype', 'constructor'};
const _platforms = {'ios', 'android', 'web', 'flutter', 'react-native'};
bool _text(Object? v, int max) =>
    v is String && v.isNotEmpty && v.length <= max;
bool _key(Object? v) => _text(v, 128) && !_reserved.contains(v);
bool _integer(Object? v, int max) => v is int && v >= 0 && v <= max;
bool httpTag(Object? v) =>
    _text(v, 256) && (v as String).codeUnits.every((c) => c >= 32 && c <= 126);
bool _json(Object? value, [int depth = 0]) {
  if (depth > maxConfigDepth) return false;
  if (value == null || value is String || value is bool) return true;
  if (value is num) return value.isFinite;
  if (value is List) return value.every((v) => _json(v, depth + 1));
  return value is Map && value.values.every((v) => _json(v, depth + 1));
}

bool _matches(Object? type, Object? value) => switch (type) {
      'bool' => value is bool,
      'number' => value is num && value.isFinite,
      'string' => value is String,
      'json' => _json(value),
      _ => false,
    };
bool _param(Object? value) {
  if (value is! Map ||
      !_key(value['k']) ||
      !_integer(value['r'], 10000) ||
      !value.containsKey('v') ||
      !_matches(value['t'], value['v'])) {
    return false;
  }
  final overrides = value['o'];
  return !value.containsKey('o') ||
      (overrides is Map &&
          overrides.entries.every((e) =>
              _platforms.contains(e.key) && _matches(value['t'], e.value)));
}

bool _experiment(Object? value) {
  if (value is! Map ||
      !_key(value['k']) ||
      !_text(value['s'], 128) ||
      (value.containsKey('p') && !_key(value['p']))) {
    return false;
  }
  final variants = value['v'];
  if (variants is! List || variants.length < 2 || variants.length > 10) {
    return false;
  }
  var bound = 0;
  final names = <String>{};
  for (final item in variants) {
    if (item is! Map ||
        !_text(item['n'], 128) ||
        !_integer(item['b'], 10000) ||
        (item['b'] as int) <= bound ||
        !item.containsKey('v') ||
        !_json(item['v']) ||
        !names.add(item['n'] as String)) {
      return false;
    }
    bound = item['b'] as int;
  }
  return bound == 10000;
}

bool _unique(List items, String field) {
  final values = items
      .whereType<Map>()
      .where((v) => v.containsKey(field))
      .map((v) => v[field])
      .toList();
  return values.toSet().length == values.length;
}

bool isConfigDocument(Object? value) {
  if (value is! Map ||
      !_integer(value['version'], 9007199254740991) ||
      !httpTag(value['etag'])) {
    return false;
  }
  final params = value['params'], experiments = value['experiments'];
  return params is List &&
      params.length <= 1000 &&
      params.every(_param) &&
      _unique(params, 'k') &&
      (!value.containsKey('experiments') ||
          (experiments is List &&
              experiments.length <= 1000 &&
              experiments.every(_experiment) &&
              _unique(experiments, 'k') &&
              _unique(experiments, 'p')));
}
