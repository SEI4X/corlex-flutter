import 'dart:convert';
import 'package:corlex_flutter/src/binding/bridge.dart';
import 'package:corlex_flutter/src/binding/protocol.dart';
import 'package:corlex_flutter/src/options.dart';

/// Synthetic bridge only; physical locks/backup/C handler admission require native probes.
class StateFixture implements StateBridge {
  String? raw = '';
  final rows = <String, String>{};
  bool failRead = false, failWrite = false;
  @override
  String? current() => failRead ? null : raw;
  @override
  Future<String> fresh() async {
    if (failRead) throw StateError('synthetic IO failure');
    return raw ?? '';
  }

  String snapshot(String owner) {
    final p = Privacy.parse(raw),
        prefix = 's:$owner:${Privacy.parse(raw)?.generation}:';
    return jsonEncode({
      'privacy': raw ?? '',
      'rows': {
        if (p?.state == ConsentState.granted)
          for (final entry in rows.entries)
            if (entry.key.startsWith(prefix)) entry.key: entry.value
      },
      if (rows.containsKey('m:$owner:consent'))
        'explicitChoice': rows['m:$owner:consent']
    });
  }

  @override
  Future<String> read(String owner) async {
    if (failRead) throw StateError('synthetic IO failure');
    return snapshot(owner);
  }

  void publish(String next) {
    final before = Privacy.parse(raw), after = Privacy.parse(next);
    if (before?.generation != after?.generation) {
      rows.removeWhere((key, _) => key.startsWith('s:'));
    }
    raw = next;
  }

  @override
  Future<String> exchange(String command) async {
    if (failWrite) throw StateError('synthetic IO failure');
    final input = jsonDecode(command) as Map, owner = input['owner'] as String;
    if (input['expected'] != raw) return snapshot(owner);
    if (input.containsKey('privacy')) {
      final next = Privacy.parse(input['privacy'] as String);
      if (next?.sdkChoice != ConsentState.granted) {
        rows.removeWhere((key, _) => key.startsWith('m:'));
      }
      publish(input['privacy'] as String);
    }
    if (input['explicitChoice'] != null) {
      rows['m:$owner:consent'] = input['explicitChoice'] as String;
    }
    final p = Privacy.parse(raw);
    if (input['changes'] is Map &&
        p?.state == ConsentState.granted &&
        input['generation'] == p?.generation) {
      for (final entry in (input['changes'] as Map).entries) {
        final key = entry.key == 'corlex_consent'
            ? 'm:$owner:consent'
            : 's:$owner:${p?.generation}:${entry.key}';
        if (entry.value == null) {
          rows.remove(key);
        } else {
          rows[key] = entry.value as String;
        }
      }
    }
    return snapshot(owner);
  }

  @override
  Future<String> revoke(String expected, String record) async {
    if (failWrite) throw StateError('synthetic IO failure');
    if (expected == raw) {
      rows.clear();
      publish(record);
    }
    return raw ?? '';
  }

  @override
  Future<String> observe(String expected, String ceiling) async {
    final p = Privacy.parse(raw);
    if (p == null || raw != expected) return raw ?? '';
    final state =
        restrict(p.sdkChoice, choice(ceiling) ?? ConsentState.pending);
    if (state != p.state) publish(Privacy.create(p.sdkChoice, state).raw);
    return raw ?? '';
  }

  @override
  Future<void> select(String owner, String generation) async {
    final p = Privacy.parse(raw);
    if (owner.length != 64 ||
        p?.generation != generation ||
        p?.state != ConsentState.granted) {
      throw StateError('scope inactive');
    }
  }
}
