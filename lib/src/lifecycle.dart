import 'package:flutter/widgets.dart';

import 'client.dart';

/// `app_open` at start, `app_background` / `app_foreground` on the app's lifecycle. Going to the
/// background also flushes the queue (the OS may stop the process soon); whatever is still queued
/// stays on disk and goes out at the next launch.
class LifecycleTracker with WidgetsBindingObserver {
  LifecycleTracker(this._client,
      {this.onForeground, this.captureEvents = true});

  final CorlexClient _client;
  final bool captureEvents;

  /// Called when the app comes back, after the event (the iOS ATT status is re-read here).
  final void Function()? onForeground;
  bool _inBackground = false;

  void start() {
    WidgetsBinding.instance.addObserver(this);
    if (captureEvents) _client.track('app_open');
  }

  void stop() => WidgetsBinding.instance.removeObserver(this);

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && !_inBackground) {
      _inBackground = true;
      if (captureEvents) _client.track('app_background');
      _client.flush();
    } else if (state == AppLifecycleState.resumed && _inBackground) {
      _inBackground = false;
      if (captureEvents) _client.track('app_foreground');
      onForeground?.call();
    }
  }
}
