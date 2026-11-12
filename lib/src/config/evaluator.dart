import 'dart:convert';

/// Remote Config evaluation: a port of `packages/domain/src/flags/bucket.ts` and
/// `remote-config/{evaluate,experiments}.ts`. The shared vectors in
/// `packages/domain/test-vectors/remote-config.json` pin it down (test/vectors_test.dart).
const int buckets = 10000;
const int _mask = 0xFFFFFFFF;

int _hash32(String text) {
  var h = 0x811c9dc5;
  for (final byte in utf8.encode(text)) {
    h ^= byte;
    h = (h * 0x01000193) & _mask;
  }
  h ^= h >> 16;
  h = (h * 0x85ebca6b) & _mask;
  h ^= h >> 13;
  h = (h * 0xc2b2ae35) & _mask;
  h ^= h >> 16;
  return h & _mask;
}

/// The stable bucket (0..9999) of a person for a key. The separator cannot occur in a key.
int bucketOf(String key, String userId) =>
    _hash32('$key\u0000$userId') % buckets;

/// The bucket of a person in an experiment.
int experimentBucket(String key, String salt, String userId) =>
    bucketOf('ab:$key:$salt', userId);

/// A resolved value; the wrapper tells "the value is null" from "does not apply".
class Resolved {
  const Resolved(this.value);

  final Object? value;
}

/// The value of one compiled parameter (`{k, t, v, r, o?}`) for a person, or null when the rollout
/// does not reach them. [platforms] are tried in order for an override: a platform override wins
/// whatever the rollout says. Outside both the caller keeps its own default.
Resolved? resolveParam(
    Map<String, Object?> param, String userId, List<String> platforms) {
  final overrides = param['o'];
  if (overrides is Map) {
    for (final platform in platforms) {
      if (overrides.containsKey(platform)) return Resolved(overrides[platform]);
    }
  }
  final rollout = param['r'] as int;
  if (rollout >= buckets || bucketOf(param['k'] as String, userId) < rollout) {
    return Resolved(param['v']);
  }
  return null;
}

/// Every parameter of the document that applies to the person, by key.
Map<String, Object?> resolveAll(
    List<Object?> params, String userId, List<String> platforms) {
  final out = <String, Object?>{};
  for (final param in params.whereType<Map<String, Object?>>()) {
    final resolved = resolveParam(param, userId, platforms);
    if (resolved != null) out[param['k'] as String] = resolved.value;
  }
  return out;
}

/// The variant a person got in an experiment (`{k, s, p?, v: [{n, b, v}]}`).
class Assignment {
  const Assignment(this.variant, this.index, this.value);

  final String variant;
  final int index;
  final Object? value;
}

Assignment? assignVariant(Map<String, Object?> experiment, String userId) {
  final bucket = experimentBucket(
      experiment['k'] as String, experiment['s'] as String, userId);
  final variants =
      (experiment['v'] as List<Object?>).cast<Map<String, Object?>>();
  final index =
      variants.indexWhere((variant) => bucket < (variant['b'] as int));
  if (index < 0) return null;
  final variant = variants[index];
  return Assignment(variant['n'] as String, index, variant['v']);
}
