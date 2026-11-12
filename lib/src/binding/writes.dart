part of 'driver.dart';

extension _StateWrites on BindingDriver {
  void _schedule() {
    _writing ??= Future<void>.microtask(_write).whenComplete(() {
      _writing = null;
      if (_pending.isNotEmpty) _schedule();
    });
  }

  Future<void> _write() async {
    while (_pending.isNotEmpty && persistent && bridge != null) {
      final changes = Map<String, String?>.from(_pending);
      _pending.clear();
      final expected = _accepted, gen = generation;
      if (expected == null || gen == null) return;
      try {
        await bridge!.exchange(jsonEncode({
          'owner': owner,
          'generation': gen,
          'expected': expected,
          'changes': changes
        }));
        if (_accepted == expected) consent;
      } on Object {
        _log('storage_error');
      }
    }
  }
}
