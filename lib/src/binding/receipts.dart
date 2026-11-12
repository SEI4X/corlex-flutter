part of 'driver.dart';

extension DurableReceipts on BindingDriver {
  /// Positive native queue readback only; a failed/unknown write cannot release a receipt.
  Future<Set<String>> durableEvents(Set<String> ids) async {
    final expected = _accepted;
    if (expected == null || !persistent) return {};
    await flush();
    try {
      final snapshot = await _readNative();
      if (snapshot.raw != expected || consent != ConsentState.granted) {
        return {};
      }
      return {
        for (final event in readBoundQueue(snapshot.rows['corlex_queue']))
          if (ids.contains(event['event_id'])) event['event_id']! as String,
      };
    } on Object {
      return {};
    }
  }
}
