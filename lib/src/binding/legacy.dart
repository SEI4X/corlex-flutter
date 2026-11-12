import 'dart:io';
import 'protocol.dart';
import '../options.dart';

/// Read only a prior refusal; unbound identity, config and events are never restored.
ConsentState? legacyConsent(Directory directory) {
  final file = File('${directory.path}/store.json');
  try {
    if (!file.existsSync()) return null;
    if (file.lengthSync() > stateMaxBytes) return ConsentState.pending;
    final value = flatJson(file.readAsStringSync(), stateMaxBytes, 1);
    if (value is! Map) return ConsentState.pending;
    final saved = choice(value['corlex_consent']);
    return saved == ConsentState.denied || saved == ConsentState.pending
        ? saved
        : null;
  } on Object {
    return ConsentState.pending;
  }
}

void discardLegacy(Directory directory) {
  for (final name in ['store.json', 'queue.jsonl']) {
    try {
      final file = File('${directory.path}/$name');
      if (file.existsSync()) file.deleteSync();
    } on Object {/* SDK-only, best effort. */}
  }
}
