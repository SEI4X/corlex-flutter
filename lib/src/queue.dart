import 'dart:convert';
import 'dart:io';

import 'limits.dart';
import 'storage.dart';
import 'queue_cache.dart';

typedef WireEvent = Map<String, Object?>;

/// Events waiting for delivery: in memory, mirrored to `queue.jsonl` (one event per line) so a
/// restart or a crash does not lose them. An event leaves the queue only after the server
/// acknowledged it or rejected it for good. Without consent ([file] null) nothing touches the disk.
class EventQueue {
  EventQueue(File? file, {KeyValueStore? store})
      : _file = file,
        _store = store {
    if (store != null) {
      _items.addAll(readBoundQueue(store.get('corlex_queue')));
    } else if (file != null) {
      _items.addAll(_load(file));
    }
  }

  File? _file;
  KeyValueStore? _store;
  final List<WireEvent> _items = [];

  int get size => _items.length;

  static List<WireEvent> _load(File file) {
    final events = <WireEvent>[];
    try {
      for (final line in file.readAsLinesSync()) {
        try {
          final event = jsonDecode(line);
          if (event is Map<String, Object?> && event['event_id'] is String) {
            events.add(event);
          }
        } on FormatException {
          // A half-written last line.
        }
      }
    } on Object {
      return events;
    }
    return events.length > maxQueue
        ? events.sublist(events.length - maxQueue)
        : events;
  }

  void push(WireEvent event) {
    _items.add(event);
    var trimmed = false;
    while (_items.length > maxQueue ||
        byteLength(jsonEncode(_items)) > maxQueueBytes) {
      _items.removeAt(0);
      trimmed = true;
    }
    if (_store != null || trimmed) {
      _rewrite();
      return;
    }
    if (_items.length >= maxQueue) {
      _items.removeRange(0, _items.length - maxQueue);
      _rewrite();
    } else {
      _append(event);
    }
  }

  bool has(String eventId) => _items.any((e) => e['event_id'] == eventId);

  List<WireEvent> peek(int count) => _items.take(count).toList();

  /// Removes exactly the events of a delivered or dropped batch.
  void drop(List<WireEvent> batch) {
    final ids = batch.map((e) => e['event_id']).toSet();
    _items.removeWhere((e) => ids.contains(e['event_id']));
    _rewrite();
  }

  void clear() {
    _items.clear();
    _store?.remove('corlex_queue');
    try {
      _file?.deleteSync();
    } on Object {
      // Already gone.
    }
  }

  /// Consent arrived: start mirroring the queue to [file].
  void enablePersistence(File file) {
    _file = file;
    _rewrite();
  }

  void enableStorePersistence(KeyValueStore store) {
    _store = store;
    _file = null;
    _rewrite();
  }

  void _append(WireEvent event) {
    try {
      final file = _file;
      if (file == null) return;
      file.parent.createSync(recursive: true);
      file.writeAsStringSync('${jsonEncode(event)}\n', mode: FileMode.append);
    } on Object {
      // The in-memory queue keeps working.
    }
  }

  void _rewrite() {
    if (_store != null) {
      _store!.set('corlex_queue', jsonEncode(_items));
      return;
    }
    try {
      final file = _file;
      if (file == null) return;
      file.parent.createSync(recursive: true);
      final lines = _items.map((e) => '${jsonEncode(e)}\n').join();
      file.writeAsStringSync(lines, flush: true);
    } on Object {
      // Same.
    }
  }
}
