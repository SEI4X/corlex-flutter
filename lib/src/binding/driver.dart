import 'dart:async';
import 'dart:convert';
import '../options.dart';
import '../storage.dart';
import '../queue_cache.dart';
import 'bridge.dart';
import 'protocol.dart';
part 'writes.dart';
part 'receipts.dart';
part 'ceiling.dart';
part 'native_view.dart';

class Activation {
  const Activation(this.granted,
      {this.preserveMemory = false, this.changed = true});
  final bool granted, preserveMemory, changed;
}

/// Owns the current immutable scope; physical writes are serialized expected-privacy CAS.
class BindingDriver implements KeyValueStore {
  BindingDriver(this.owner, this.bridge,
      {this.readCeiling, void Function(String)? log})
      : _log = log ?? ((_) {});
  final String owner;
  final StateBridge? bridge;
  final Future<ConsentState> Function()? readCeiling;
  final void Function(String) _log;
  final _view = _NativePrivacyView();
  final _rows = <String, String>{}, _pending = <String, String?>{};
  String? _accepted, _memoryFence;
  Privacy? _scope;
  ConsentState _ceiling = ConsentState.granted;
  bool _localDenied = false,
      _memoryGranted = false,
      _closed = false,
      _activating = false;
  int _revision = 0, _ceilingRead = 0, _ceilingVersion = 0;
  int get ceilingVersion => _ceilingVersion;
  bool get ceilingGranted => _ceiling == ConsentState.granted;
  Future<void>? _writing, _revoking;
  void Function()? onInvalidate;
  String? get generation => _scope?.generation;
  bool get persistent =>
      bridge != null && !_memoryGranted && consent == ConsentState.granted;
  String? _raw() => _view.current(_diskRaw());
  String? _diskRaw() {
    try {
      return bridge?.current();
    } on Object {
      return null;
    }
  }

  ConsentState get consent {
    if (_closed || _localDenied) return ConsentState.denied;
    final raw = _raw(), p = Privacy.parse(raw);
    if (_memoryGranted && raw == _memoryFence) {
      return restrict(ConsentState.granted, _ceiling);
    }
    if (raw == _accepted && p != null) return restrict(p.state, _ceiling);
    if (_activating && p?.state == ConsentState.granted) {
      return ConsentState.pending;
    }
    if (_scope != null || _memoryGranted) _invalidate();
    return p?.state == ConsentState.denied
        ? ConsentState.denied
        : ConsentState.pending;
  }

  void _invalidate() {
    _scope = null;
    _accepted = null;
    _memoryGranted = false;
    _rows.clear();
    _pending.clear();
    onInvalidate?.call();
  }

  Future<ConsentState> prepare(ConsentState requested) async {
    final revision = _revision;
    try {
      await _ceilingNow();
      if (_closed || revision != _revision) return ConsentState.pending;
      if (bridge == null) {
        _localDenied = requested == ConsentState.denied;
        return _localDenied ? ConsentState.denied : ConsentState.pending;
      }
      await _freshNative();
      var value = await _readNative();
      if (_closed || revision != _revision) return ConsentState.pending;
      final privacy = value.privacy;
      var choice = requested;
      if (privacy == null && value.raw.isNotEmpty) return ConsentState.pending;
      if (privacy == null) {
        choice = value.legacyChoice == ConsentState.denied ||
                value.legacyChoice == ConsentState.pending
            ? value.legacyChoice!
            : requested;
      } else if (requested == ConsentState.denied) {
        choice = ConsentState.denied;
      } else if (requested == ConsentState.pending &&
          value.explicitChoice != ConsentState.granted &&
          privacy.sdkChoice == ConsentState.granted) {
        choice = ConsentState.pending;
      } else {
        _accept(value);
        return consent;
      }
      final next = Privacy.create(choice, _ceiling);
      value = Snapshot.parse(
          await bridge!.exchange(jsonEncode(
              {'owner': owner, 'expected': value.raw, 'privacy': next.raw})),
          owner);
      _accept(value);
      return consent;
    } on Object {
      _log('storage_error');
      return consent;
    }
  }

  void _accept(Snapshot value) {
    _accepted = value.raw;
    _scope = value.privacy;
    _rows.clear();
    if (_scope?.state == ConsentState.granted && value.raw == _raw()) {
      _rows.addAll(value.rows);
    }
    if (value.explicitChoice != null) {
      _rows['corlex_consent'] = value.explicitChoice!.name;
    }
  }

  Future<bool> fresh() async {
    if (_closed || _localDenied) return false;
    final revision = _revision;
    try {
      await _ceilingNow();
      if (bridge != null) {
        final checked = await _freshNative();
        if (checked != _accepted &&
            !(_memoryGranted && checked == _memoryFence)) {
          _invalidate();
          return false;
        }
      }
      return revision == _revision && consent == ConsentState.granted;
    } on Object {
      if (_memoryGranted && consent == ConsentState.granted) return true;
      _invalidate();
      return false;
    }
  }

  Future<Activation> activate({bool explicit = true}) async {
    final revision = _revision;
    await _ceilingNow();
    if (bridge != null) {
      try {
        await _freshNative();
      } on Object {/* explicit memory fallback only */}
    }
    if (revision != _revision || _closed) return const Activation(false);
    final before = _raw(), p = Privacy.parse(before);
    if (!explicit &&
        ((p?.sdkChoice != ConsentState.granted &&
                !(_memoryGranted && before == _memoryFence)) ||
            _localDenied)) {
      return const Activation(false);
    }
    if (consent == ConsentState.granted) {
      if (explicit) set('corlex_consent', 'granted');
      return const Activation(true, preserveMemory: true, changed: false);
    }
    _localDenied = false;
    if (p == null || bridge == null) {
      if (!explicit) return const Activation(false);
      _invalidate();
      _memoryFence = before;
      _memoryGranted = true;
      return Activation(consent == ConsentState.granted);
    }
    final preserve = _accepted == before &&
        p.state == ConsentState.pending &&
        p.sdkChoice == ConsentState.pending &&
        _ceiling == ConsentState.granted;
    final next = Privacy.create(
        ConsentState.granted, _ceiling, preserve ? p.generation : null);
    _activating = true;
    try {
      final value = Snapshot.parse(
          await bridge!.exchange(jsonEncode({
            'owner': owner,
            'expected': before,
            'privacy': next.raw,
            if (explicit) 'explicitChoice': 'granted'
          })),
          owner);
      if (revision != _revision || value.raw != next.raw || _closed) {
        return const Activation(false);
      }
      if (await _freshNative() != value.raw ||
          revision != _revision ||
          _closed) {
        return const Activation(false);
      }
      _accept(value);
      return Activation(consent == ConsentState.granted,
          preserveMemory: preserve);
    } on Object {
      _log('storage_error');
      if (!explicit || revision != _revision) return const Activation(false);
      _invalidate();
      _memoryFence = before;
      _memoryGranted = true;
      return Activation(consent == ConsentState.granted);
    } finally {
      _activating = false;
    }
  }

  void deny() {
    if (_closed) return;
    final expected = _view.lastRaw ?? _accepted ?? '';
    ++_revision;
    _view.begin();
    _localDenied = true;
    _invalidate();
    final next = Privacy.create(ConsentState.denied, ConsentState.denied);
    _revoking = _revoke(next, expected);
  }

  Future<void> _revoke(Privacy next, String expected) async {
    try {
      await bridge?.revoke(expected, next.raw);
    } on Object {
      _log('storage_error');
    }
  }

  @override
  String? get(String key) =>
      consent == ConsentState.granted ? _rows[key] : null;
  @override
  void set(String key, String value) {
    final limit = stateLimits[key];
    if (limit == null ||
        value.length > limit ||
        utf8.encode(value).length > limit ||
        consent != ConsentState.granted) {
      return;
    }
    _rows[key] = value;
    if (persistent) {
      _pending[key] = value;
      _schedule();
    }
  }

  @override
  void remove(String key) {
    if (consent != ConsentState.granted) return;
    _rows.remove(key);
    if (persistent) {
      _pending[key] = null;
      _schedule();
    }
  }

  Future<void> flush() async {
    await _revoking;
    while (_writing != null) {
      await _writing;
    }
  }

  Future<bool> select() async {
    if (!persistent || generation == null || !await fresh()) return false;
    try {
      await bridge!.select(owner, generation!);
      return consent == ConsentState.granted;
    } on Object {
      return false;
    }
  }

  void close() {
    ++_revision;
    _view.begin();
    _closed = true;
    _pending.clear();
    onInvalidate = null;
  }
}
