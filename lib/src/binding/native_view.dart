part of 'driver.dart';

/// A known native refusal remains authoritative when failed IO leaves its older file readable.
class _NativePrivacyView {
  String? lastRaw, _negative, _baseline;
  int _ticket = 0;
  int begin() => ++_ticket;
  void observe(String raw, String? disk, int ticket) {
    if (ticket != _ticket) return;
    final p = Privacy.parse(raw);
    if (p == null) return;
    lastRaw = raw;
    if (p.state != ConsentState.granted) {
      _negative = raw;
      _baseline = disk;
    } else {
      _negative = null;
      _baseline = null;
    }
  }

  String? current(String? disk) {
    final negative = Privacy.parse(_negative);
    if (negative == null) return disk;
    final physical = Privacy.parse(disk);
    if (disk != _baseline &&
        physical != null &&
        physical.state != ConsentState.granted &&
        physical.state.index >= negative.state.index) {
      return disk;
    }
    return _negative;
  }
}

extension _NativeView on BindingDriver {
  Future<String> _freshNative() async {
    final ticket = _view.begin();
    final raw = await bridge!.fresh();
    _view.observe(raw, _diskRaw(), ticket);
    return raw;
  }

  Future<Snapshot> _readNative() async {
    final ticket = _view.begin();
    final snapshot = Snapshot.parse(await bridge!.read(owner), owner);
    _view.observe(snapshot.raw, _diskRaw(), ticket);
    return snapshot;
  }
}
