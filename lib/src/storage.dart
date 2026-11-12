import 'dart:convert';
import 'dart:io';

/// Small string store (consent, ids, the saved Remote Config document).
abstract class KeyValueStore {
  String? get(String key);
  void set(String key, String value);
  void remove(String key);
}

/// Memory only: the exposure memory of a session, tests.
class MemoryStore implements KeyValueStore {
  final Map<String, String> _values = {};

  @override
  String? get(String key) => _values[key];

  @override
  void set(String key, String value) => _values[key] = value;

  @override
  void remove(String key) => _values.remove(key);
}

/// One JSON file in the app's support directory. Writes are synchronous and tiny (a few keys),
/// so a crash right after `set` still finds the value. A disk error is not the app's problem.
class FileStore implements KeyValueStore {
  FileStore(Directory directory)
      : _file = File('${directory.path}/store.json') {
    try {
      final data = jsonDecode(_file.readAsStringSync());
      if (data is Map) {
        data.forEach((k, v) {
          if (k is String && v is String) _values[k] = v;
        });
      }
    } on Object {
      // No file yet, or it is damaged: start empty.
    }
  }

  final File _file;
  final Map<String, String> _values = {};

  @override
  String? get(String key) => _values[key];

  @override
  void set(String key, String value) {
    _values[key] = value;
    _save();
  }

  @override
  void remove(String key) {
    if (_values.remove(key) != null) _save();
  }

  void _save() {
    try {
      _file.parent.createSync(recursive: true);
      _file.writeAsStringSync(jsonEncode(_values), flush: true);
    } on Object {
      // Disk full or gone: the in-memory copy keeps working.
    }
  }
}
