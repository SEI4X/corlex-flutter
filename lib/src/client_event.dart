part of 'client.dart';

extension _EventBuilder on CorlexClient {
  WireEvent _buildEvent(
      String name, Map<String, Object?>? properties, CaptureMeta meta) {
    final props = sanitizeProperties(properties);
    // `build` and `framework` are the SDK's own: an app value never replaces them.
    final build = exactRelease(meta.build ?? device.build, 32);
    props.remove('build');
    if (build.isNotEmpty) props['build'] = build;
    props['framework'] = 'flutter';
    final eventId = meta.eventId;
    final event = <String, Object?>{
      'event_id': eventId != null && uuidPattern.hasMatch(eventId)
          ? eventId
          : newUuid(),
      'name': name,
      'timestamp': isoTime(meta.timestamp ?? DateTime.now()),
      'anonymous_id': _identity!.anonymousId,
      'properties': props,
      'context': _context(meta),
    };
    final user = _identity!.userId;
    if (user != null) event['user_id'] = user;
    return event;
  }

  Map<String, Object?> _context(CaptureMeta meta) {
    final version = exactRelease(meta.appVersion ?? device.appVersion, 128);
    final model = meta.deviceModel ?? device.deviceModel;
    final osVersion = meta.osVersion ?? device.osVersion;
    return {
      'platform': device.platform,
      'os': device.os,
      if (osVersion.isNotEmpty) 'os_version': truncateBytes(osVersion, 128),
      if (version.isNotEmpty) 'app_version': version,
      if (model.isNotEmpty) 'device_model': truncateBytes(model, 128),
      'locale': _locale(),
      'sdk': {'name': 'corlex-flutter', 'version': sdkVersion},
    };
  }
}
