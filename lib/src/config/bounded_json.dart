import 'dart:convert';
import 'document.dart';

/// Bound allocation/depth/key count before decoding; reject duplicate decoded object keys.
Object? parseConfigJson(String text, {bool cache = false}) {
  final limit = maxConfigBytes + (cache ? 1024 : 0);
  if (text.length > limit || utf8.encode(text).length > limit) return null;
  try {
    final scan = _JsonScan(text, maxConfigDepth + (cache ? 2 : 0));
    for (var i = 0; i < text.length; i++) {
      if (!scan.accept(i)) return null;
    }
    return scan.complete ? jsonDecode(text) : null;
  } on Object {
    return null;
  }
}

class _JsonScan {
  _JsonScan(this.text, this.maxDepth);
  final String text;
  final int maxDepth;
  final stack = <Set<String>?>[];
  bool quoted = false, escaped = false;
  int start = 0, keys = 0;
  bool get complete => !quoted && stack.isEmpty;
  bool accept(int i) {
    final c = text.codeUnitAt(i);
    if (quoted) return _string(i, c);
    if (c == 34) {
      quoted = true;
      start = i;
    } else if (c == 123 || c == 91) {
      stack.add(c == 123 ? <String>{} : null);
      if (stack.length > maxDepth) return false;
    } else if (c == 125 || c == 93) {
      if (stack.isEmpty) return false;
      stack.removeLast();
    }
    return true;
  }

  bool _string(int i, int c) {
    if (escaped) {
      escaped = false;
      return true;
    }
    if (c == 92) {
      escaped = true;
      return true;
    }
    if (c != 34) return true;
    quoted = false;
    var next = i + 1;
    while (next < text.length && ' \r\n\t'.contains(text[next])) {
      next++;
    }
    if (next >= text.length || text[next] != ':') return true;
    if (++keys > 65536 || stack.isEmpty) return false;
    final objectKeys = stack.last;
    return objectKeys != null &&
        objectKeys.add(jsonDecode(text.substring(start, i + 1)) as String);
  }
}
