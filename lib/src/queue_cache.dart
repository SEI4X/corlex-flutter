import 'dart:convert';
import 'limits.dart';
import 'queue.dart' show WireEvent;

const maxQueueBytes = 2 * 1024 * 1024;
bool _text(Object? v, [int max = 256]) =>
    v is String && v.isNotEmpty && v.length <= max;
bool _event(Object? value) {
  if (value is! Map<String, Object?> ||
      !_text(value['event_id']) ||
      !_text(value['name'], 128) ||
      !namePattern.hasMatch(value['name'] as String)) {
    return false;
  }
  if (!_text(value['timestamp'], 128) ||
      DateTime.tryParse(value['timestamp'] as String) == null) {
    return false;
  }
  final context = value['context'];
  if (value['properties'] is! Map ||
      context is! Map ||
      !_text(context['platform']) ||
      context['sdk'] is! Map) {
    return false;
  }
  final sdk = context['sdk'] as Map;
  if (!_text(sdk['name']) || !_text(sdk['version'])) return false;
  for (final name in ['anonymous_id', 'user_id']) {
    final item = value[name];
    if (item != null && (item is! String || byteLength(item) > maxId)) {
      return false;
    }
  }
  return byteLength(jsonEncode(value)) <= maxEventBytes;
}

List<WireEvent> readBoundQueue(String? text) {
  if (text == null ||
      text.length > maxQueueBytes ||
      byteLength(text) > maxQueueBytes) {
    return [];
  }
  var depth = 0, quoted = false, escaped = false;
  for (final c in text.codeUnits) {
    if (quoted) {
      if (escaped) {
        escaped = false;
      } else if (c == 92) {
        escaped = true;
      } else if (c == 34) {
        quoted = false;
      }
    } else if (c == 34) {
      quoted = true;
    } else if (c == 123 || c == 91) {
      if (++depth > 8) return [];
    } else if (c == 125 || c == 93) {
      if (--depth < 0) return [];
    }
  }
  if (depth != 0 || quoted) return [];
  try {
    final value = jsonDecode(text);
    if (value is! List || !value.every(_event)) return [];
    return value
        .skip(value.length > maxQueue ? value.length - maxQueue : 0)
        .cast<WireEvent>()
        .toList();
  } on Object {
    return [];
  }
}
