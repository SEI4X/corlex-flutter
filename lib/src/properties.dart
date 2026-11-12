import 'limits.dart';

/// Marks a value the protocol cannot represent; the caller drops it.
const Object _drop = Object();

/// Makes a value fit the protocol: long strings are cut, what cannot be represented (functions,
/// objects, too deep nesting) is dropped. `depth` follows the Go validator: `properties` itself is
/// level 1 and an array counts as a level (sdk-core/properties.ts).
Object? _clean(Object? value, int depth) {
  if (value == null || value is bool) return value;
  if (value is num) return value.isFinite ? value : null;
  if (value is String) return truncateBytes(value, maxPropertyString);
  if (value is DateTime) return value.toUtc().toIso8601String();
  if (value is Iterable) return _cleanList(value, depth);
  if (value is Map) {
    return depth + 1 > maxDepth ? _drop : _cleanMap(value, depth + 1);
  }
  return _drop;
}

Object? _cleanList(Iterable<Object?> items, int depth) {
  if (depth + 1 > maxDepth) return _drop;
  return items.take(maxArray).map((item) {
    final cleaned = _clean(item, depth + 1);
    return identical(cleaned, _drop) ? null : cleaned;
  }).toList();
}

Map<String, Object?> _cleanMap(Map<Object?, Object?> input, int depth) {
  final out = <String, Object?>{};
  for (final entry in input.entries) {
    final key = truncateBytes('${entry.key}', maxPropertyKey);
    if (key.isEmpty || out.length >= maxProperties) continue;
    final value = _clean(entry.value, depth);
    if (!identical(value, _drop)) out[key] = value;
  }
  return out;
}

/// Properties the protocol accepts, from anything a caller may pass.
Map<String, Object?> sanitizeProperties(Object? input) =>
    input is Map ? _cleanMap(input, 1) : <String, Object?>{};
