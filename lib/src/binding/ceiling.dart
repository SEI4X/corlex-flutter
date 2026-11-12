part of 'driver.dart';

extension _ObservedCeiling on BindingDriver {
  Future<void> _ceilingNow() async {
    final read = readCeiling;
    if (read == null) return;
    final revision = _revision, ticket = ++_ceilingRead;
    ConsentState state;
    try {
      state = await read();
    } on Object {
      state = ConsentState.pending;
    }
    if (revision != _revision || ticket != _ceilingRead || _closed) return;
    if (state != _ceiling) {
      ++_ceilingVersion;
      _ceiling = state;
      if (state != ConsentState.granted) {
        final memory = _memoryGranted, fence = _memoryFence;
        _invalidate();
        if (memory && _raw() == fence) {
          _memoryGranted = true;
          _memoryFence = fence;
        }
      }
    }
    try {
      await _publishCeiling(ticket, revision);
    } on Object {
      _log('storage_error');
    }
  }

  Future<void> _publishCeiling(int ticket, int revision) async {
    var before = _raw();
    for (var attempt = 0; attempt < 3 && bridge != null; attempt++) {
      if (ticket != _ceilingRead || revision != _revision || _closed) return;
      final current = Privacy.parse(before);
      if (current == null ||
          current.state == restrict(current.sdkChoice, _ceiling)) {
        return;
      }
      final nativeTicket = _view.begin();
      before = await bridge!.observe(current.raw, _ceiling.name);
      _view.observe(before, _diskRaw(), nativeTicket);
    }
  }
}
