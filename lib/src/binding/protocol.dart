import 'dart:convert';
import '../options.dart';
import '../limits.dart';

const stateMaxBytes = 8 * 1024 * 1024;
const stateLimits = {
  'corlex_aid': 4096,
  'corlex_uid': 4096,
  'corlex_consent': 16,
  'corlex_queue': 2 * 1024 * 1024,
  'corlex_cfg': 1024 * 1024 + 1024
};
ConsentState? choice(Object? value) => switch (value) {
      'granted' => ConsentState.granted,
      'pending' => ConsentState.pending,
      'denied' => ConsentState.denied,
      _ => null
    };
ConsentState restrict(ConsentState sdk, ConsentState ceiling) =>
    sdk.index > ceiling.index ? sdk : ceiling;

// ConsentState is declared granted,pending,denied: larger index is more restrictive.
class Privacy {
  Privacy(this.raw, this.generation, this.state, this.sdkChoice);
  final String raw, generation;
  final ConsentState state, sdkChoice;
  static Privacy? parse(String? raw) {
    if (raw == null ||
        raw.isEmpty ||
        raw.length > 256 ||
        byteLength(raw) > 256) {
      return null;
    }
    try {
      final row = flatJson(raw, 256, 1);
      if (row is! Map ||
          (row.length != 2 && row.length != 3) ||
          row['generation'] is! String ||
          !uuidPattern.hasMatch(row['generation'] as String)) {
        return null;
      }
      if (row.keys
          .any((key) => !{'generation', 'state', 'sdkChoice'}.contains(key))) {
        return null;
      }
      final state = choice(row['state']),
          sdk =
              row.length == 2 ? choice(row['state']) : choice(row['sdkChoice']);
      if (state == null || sdk == null || state.index < sdk.index) return null;
      return Privacy(raw, row['generation'] as String, state, sdk);
    } on Object {
      return null;
    }
  }

  static Privacy create(ConsentState sdk, ConsentState ceiling,
      [String? generation]) {
    final id = generation ?? newUuid(), state = restrict(sdk, ceiling);
    return Privacy(
        jsonEncode(
            {'generation': id, 'state': state.name, 'sdkChoice': sdk.name}),
        id,
        state,
        sdk);
  }
}

Object? flatJson(String text, int limit, int maxDepth) {
  if (text.length > limit || byteLength(text) > limit) {
    throw const FormatException('state_invalid');
  }
  final scan = _FlatControlScan(text, maxDepth);
  for (var i = 0; i < text.length; i++) {
    if (!scan.accept(i)) throw const FormatException('state_invalid');
  }
  if (!scan.complete) throw const FormatException('state_invalid');
  return jsonDecode(text);
}

class _FlatControlScan {
  _FlatControlScan(this.text, this.depth);
  final String text;
  final int depth;
  final _objects = <Set<String>>[];
  bool _quoted = false, _escaped = false;
  int _start = 0, _keys = 0;
  bool get complete => !_quoted && _objects.isEmpty;
  bool accept(int i) {
    final c = text.codeUnitAt(i);
    if (_quoted) return _string(i, c);
    if (c == 34) {
      _quoted = true;
      _start = i;
    } else if (c == 123) {
      _objects.add({});
      if (_objects.length > depth) return false;
    } else if (c == 125) {
      if (_objects.isEmpty) return false;
      _objects.removeLast();
    } else if (c == 91 || c == 93) {
      return false;
    }
    return true;
  }

  bool _string(int i, int c) {
    if (_escaped) {
      _escaped = false;
      return true;
    }
    if (c == 92) {
      _escaped = true;
      return true;
    }
    if (c != 34) return true;
    _quoted = false;
    var next = i + 1;
    while (next < text.length && ' \r\n\t'.contains(text[next])) {
      next++;
    }
    if (next >= text.length || text[next] != ':') return true;
    if (++_keys > 16 || _objects.isEmpty) return false;
    return _objects.last
        .add(jsonDecode(text.substring(_start, i + 1)) as String);
  }
}

class Snapshot {
  Snapshot(this.raw, this.rows, {this.explicitChoice, this.legacyChoice});
  final String raw;
  final Map<String, String> rows;
  final ConsentState? explicitChoice, legacyChoice;
  Privacy? get privacy => Privacy.parse(raw);
  static Snapshot parse(String text, String owner) {
    final value = flatJson(text, stateMaxBytes + 1024, 2);
    if (value is! Map || value['privacy'] is! String || value['rows'] is! Map) {
      throw const FormatException('state_invalid');
    }
    final raw = value['privacy'] as String,
        p = Privacy.parse(raw),
        rows = <String, String>{};
    final entries = (value['rows'] as Map).entries;
    if (entries.length > stateLimits.length) {
      throw const FormatException('state_invalid');
    }
    final prefix = 's:$owner:${p?.generation}:';
    for (final entry in entries) {
      if (p?.state != ConsentState.granted ||
          entry.key is! String ||
          !(entry.key as String).startsWith(prefix)) {
        throw const FormatException('state_invalid');
      }
      final key = (entry.key as String).substring(prefix.length),
          item = entry.value;
      final limit = stateLimits[key];
      if (limit == null ||
          item is! String ||
          item.length > limit ||
          byteLength(item) > limit) {
        throw const FormatException('state_invalid');
      }
      rows[key] = item;
    }
    return Snapshot(raw, rows,
        explicitChoice: choice(value['explicitChoice']),
        legacyChoice: choice(value['legacyChoice']));
  }
}
