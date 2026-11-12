part of 'client.dart';

extension _BoundClient on CorlexClient {
  void _bindingFence() {
    final selected = binding;
    if (selected == null || _disposed) return;
    final permission = selected.consent;
    if (permission != ConsentState.granted &&
        _consent == ConsentState.granted) {
      _invalidateBinding();
    }
    if (permission == ConsentState.denied) _consent = ConsentState.denied;
  }

  void _invalidateBinding() {
    _consent = ConsentState.pending;
    _sender?.dispose();
    _sender = null;
    pauseHttp(http);
    remote?.destroy();
    remote = null;
    _queue?.clear();
    _queue = null;
    _identity = null;
    _exposures.clear();
    if (_bindingGrant == null) _bindingJobs.clear();
  }

  bool _deferBound(void Function() job) {
    if (binding == null ||
        _bindingGrant == null ||
        _consent == ConsentState.granted) {
      return false;
    }
    if (_bindingJobs.length < maxQueue) _bindingJobs.add(job);
    return true;
  }

  void _grantBound({bool explicit = true}) {
    if (_disposed || _bindingGrant != null || binding == null) return;
    _bindingGrant =
        _activateBound(explicit).whenComplete(() => _bindingGrant = null);
  }

  Future<void> _activateBound(bool explicit) async {
    final result = await binding!.activate(explicit: explicit);
    if (_disposed) return;
    if (result.granted) {
      if (result.changed || _consent != ConsentState.granted) {
        if (result.preserveMemory && _queue != null) {
          _consent = ConsentState.granted;
          resumeHttp(http);
          _identity?.persist();
          _queue?.enableStorePersistence(store);
          _sender?.resume();
          _startRemoteConfig();
        } else {
          _invalidateBinding();
          start(ConsentState.granted);
        }
        onConsentChanged?.call(ConsentState.granted);
      }
      for (final job in List.of(_bindingJobs)) {
        job();
      }
    }
    _bindingJobs.clear();
  }

  Future<void> _flushBinding() => _bindingFlush ??=
      _performBoundFlush().whenComplete(() => _bindingFlush = null);
  Future<void> _performBoundFlush() async {
    await _bindingGrant;
    await binding?.flush();
    if (consent == ConsentState.granted) await _sender?.flush();
    await binding?.flush();
  }

  Future<void> _refreshBindingCeiling() async {
    final selected = binding;
    if (selected == null || _disposed) return;
    final version = selected.ceilingVersion;
    await selected.fresh();
    _bindingFence();
    if (_consent != ConsentState.granted &&
        selected.ceilingGranted &&
        version != selected.ceilingVersion) {
      _grantBound(explicit: false);
    }
    await _bindingGrant;
  }
}
