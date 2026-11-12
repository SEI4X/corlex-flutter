import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'http.dart';
import 'queue.dart';

const Duration _backoffBase = Duration(seconds: 1);
const Duration _backoffMax = Duration(seconds: 60);
const Duration _retryAfterMax = Duration(minutes: 5);

/// `Retry-After` as a duration; only the seconds form is used.
Duration? parseRetryAfter(String? value) {
  if (value == null || !RegExp(r'^\d+$').hasMatch(value.trim())) return null;
  final delay = Duration(seconds: int.parse(value.trim()));
  return delay > _retryAfterMax ? _retryAfterMax : delay;
}

/// Exponential backoff with equal jitter: half fixed, half random (same as sdk-core).
Duration backoffDelay(int attempt, Random random) {
  final ceiling = min(
    _backoffBase.inMilliseconds * pow(2, attempt - 1).toInt(),
    _backoffMax.inMilliseconds,
  );
  return Duration(
      milliseconds: (ceiling / 2 + random.nextDouble() * ceiling / 2).round());
}

enum _Kind { ok, drop, split, halt, retry }

class _Outcome {
  const _Outcome(this.kind, {this.status = 0, this.retryAfter});

  final _Kind kind;
  final int status;
  final Duration? retryAfter;
}

_Outcome _classify(HttpReply reply, int count) {
  final status = reply.status;
  if (status >= 200 && status < 300) return const _Outcome(_Kind.ok);
  if (status == 401 || status == 403) {
    return _Outcome(_Kind.halt, status: status);
  }
  if (status == 413) {
    return count > 1
        ? const _Outcome(_Kind.split)
        : _Outcome(_Kind.drop, status: status);
  }
  if ((status >= 300 && status < 400) || status == 429 || status >= 500) {
    return _Outcome(_Kind.retry, retryAfter: parseRetryAfter(reply.retryAfter));
  }
  return _Outcome(_Kind.drop, status: status);
}

typedef TimerFactory = Timer Function(Duration delay, void Function() callback);

/// Delivers the queue to `POST /v1/batch`, with the policy of sdk-core: events leave the queue only
/// after a 2xx or a final 4xx; 5xx, 429 and network errors back off (honouring `Retry-After`), a 413
/// halves the batch, 401/403 stop sending and clear the queue. A retry sends the same events with
/// the same `event_id`, so the server can drop duplicates.
class Sender {
  Sender({
    required this.queue,
    required this.http,
    required this.endpoint,
    required this.key,
    required this.batchSize,
    required this.flushInterval,
    required this.log,
    TimerFactory? timer,
    Random? random,
  })  : _timer = timer ?? Timer.new,
        _random = random ?? Random(),
        _limit = batchSize;

  final EventQueue queue;
  final Http http;
  final String endpoint;
  final String key;
  final int batchSize;
  final Duration flushInterval;
  final void Function(String) log;
  final TimerFactory _timer;
  final Random _random;

  Timer? _armed;
  Future<void>? _inflight;
  int _attempts = 0;
  int _limit;
  bool _backingOff = false;
  bool _paused = false;
  bool _rejected = false;
  int _epoch = 0;

  bool get _stopped => _paused || _rejected;

  /// Called after an event was queued: send now when a batch is full, else on the interval.
  void schedule() {
    if (_stopped || queue.size == 0 || _backingOff) return;
    if (queue.size >= batchSize) {
      unawaited(flush());
    } else {
      _armed ??= _timer(flushInterval, _fire);
    }
  }

  /// Sends everything queued. Completes when the queue is empty or delivery failed for now (a retry
  /// is then scheduled). Concurrent calls share one run.
  Future<void> flush() {
    final epoch = _epoch;
    return _inflight ??= _drain().whenComplete(() {
      _inflight = null;
      if (epoch != _epoch) schedule();
    });
  }

  /// Opt-out: stop sending until [resume].
  void stop() {
    _paused = true;
    _epoch++;
    _backingOff = false;
    pauseHttp(http);
    _disarm();
  }

  void resume() {
    resumeHttp(http);
    _paused = false;
    schedule();
  }

  void dispose() => stop();

  void _fire() {
    _armed = null;
    _backingOff = false;
    unawaited(flush());
  }

  void _disarm() {
    _armed?.cancel();
    _armed = null;
  }

  Future<void> _drain() async {
    _disarm();
    _backingOff = false;
    while (!_stopped && queue.size > 0) {
      final epoch = _epoch;
      final batch = queue.peek(_limit);
      final outcome = await _post(batch);
      if (_stopped) return;
      if (epoch != _epoch) continue;
      if (!_apply(outcome, batch)) return;
    }
  }

  /// Returns whether the drain loop may continue.
  bool _apply(_Outcome outcome, List<WireEvent> batch) {
    switch (outcome.kind) {
      case _Kind.ok:
        _attempts = 0;
        _limit = min(_limit * 2, batchSize);
        queue.drop(batch);
        return true;
      case _Kind.drop:
        log('dropping ${batch.length} event(s): server answered ${outcome.status}');
        queue.drop(batch);
        return true;
      case _Kind.split:
        _limit = max(1, batch.length ~/ 2);
        return true;
      case _Kind.halt:
        log('key rejected (${outcome.status}); events are not sent');
        _rejected = true;
        queue.clear();
        return false;
      case _Kind.retry:
        _retryLater(outcome.retryAfter);
        return false;
    }
  }

  void _retryLater(Duration? retryAfter) {
    _attempts += 1;
    var delay = backoffDelay(_attempts, _random);
    if (retryAfter != null && retryAfter > delay) delay = retryAfter;
    log('delivery failed, retry in ${delay.inMilliseconds} ms (attempt $_attempts)');
    _backingOff = true;
    _disarm();
    _armed = _timer(delay, _fire);
  }

  Future<_Outcome> _post(List<WireEvent> batch) async {
    try {
      final reply = await http.post(
        Uri.parse('$endpoint/v1/batch'),
        jsonEncode({'events': batch}),
        {'X-Corlex-Key': key},
      );
      return _classify(reply, batch.length);
    } on Object {
      return const _Outcome(_Kind.retry);
    }
  }
}
