import 'dart:convert';
import 'dart:io';

import '../client.dart';
import '../limits.dart';
import '../queue_cache.dart' show maxQueueBytes;
import '../release.dart';
import 'privacy.dart';
import 'native_frames.dart';
import '../platform.dart';
import '../options.dart';
import '../binding/driver.dart';
import 'dart_stack.dart';

/// A native crash report of an earlier launch, as the contract wants it
/// (services/ingest/docs/protocol.md section 4, "Native SDKs").
class NativeCrash {
  const NativeCrash({
    required this.crashId,
    required this.timestamp,
    required this.properties,
    this.appVersion,
    this.build,
    this.osVersion,
    this.deviceModel,
  });

  final String crashId;
  final DateTime timestamp;
  final Map<String, Object?> properties;
  final String? appVersion;
  final String? build;
  final String? osVersion;
  final String? deviceModel;
}

/// Reads one report. iOS: a JSON header line, then one tab-separated line per frame,
/// `F, debug_id, image_addr, addr, image` and an optional `fn` (the file the C signal handler
/// writes, the same as the iOS SDK's).
/// Android: one JSON object with `frames` as `Throwable.getStackTrace()` gave them.
NativeCrash? parseNativeReport(String os, String data,
    {bool captureErrorMessages = false, CrashScope? scope}) {
  if (data.length > 256 * 1024 || byteLength(data) > 256 * 1024) return null;
  try {
    if (scope != null) {
      final header = jsonDecode(os == 'iOS' ? data.split('\n').first : data);
      if (header is! Map ||
          header['binding_owner'] != scope.owner ||
          header['binding_generation'] != scope.generation) {
        return null;
      }
    }
    final crash = os == 'iOS' ? _parseIos(data) : _parseAndroid(data);
    if (crash == null) return null;
    final props = crash.properties;
    final name = props['name'] as String;
    props['name'] = props['source'] == 'signal' &&
            RegExp(r'^SIG[A-Z0-9]{1,10}$').hasMatch(name)
        ? name
        : props['source'] == 'java_exception'
            ? errorType(name, fallback: 'NativeError')
            : 'NativeError';
    props['message'] = captureErrorMessages
        ? detailedMessage(props['message'] as String)
        : 'Error details omitted';
    props['frames'] = safeNativeFrames(props['frames']);
    return NativeCrash(
        crashId: crash.crashId,
        timestamp: crash.timestamp,
        properties: props,
        appVersion: exactRelease(crash.appVersion, 128),
        build: exactRelease(crash.build, 32),
        osVersion: crash.osVersion,
        deviceModel: crash.deviceModel);
  } on Object {
    return null;
  }
}

NativeCrash? _parseIos(String data) {
  if (data.length > 512 * 1024) return null;
  final lines = data.split('\n').where((l) => l.isNotEmpty).toList();
  if (lines.isEmpty) return null;
  final header = jsonDecode(lines.first);
  if (header is! Map) return null;
  final frames =
      lines.skip(1).take(maxCrashFrames).map(_iosFrame).nonNulls.toList();
  final properties = _base(header, 'signal', frames);
  final arch = header['arch'];
  if ({'arm64', 'x86_64', 'armv7', 'unknown'}.contains(arch)) {
    properties['arch'] = arch;
  }
  return _crash(header, properties);
}

Map<String, Object?>? _iosFrame(String line) {
  final fields = line.split('\t');
  if (fields.length < 5 || fields[0] != 'F' || !fields[3].startsWith('0x')) {
    return null;
  }
  final frame = <String, Object?>{'addr': fields[3]};
  if (fields[1] != '-') {
    frame['debug_id'] = fields[1];
    frame['image_addr'] = fields[2];
  }
  if (fields[4] != '-') frame['image'] = fields[4];
  if (fields.length >= 6 && fields[5].isNotEmpty) frame['fn'] = fields[5];
  return frame;
}

NativeCrash? _parseAndroid(String data) {
  final report = jsonDecode(data);
  if (report is! Map) return null;
  final frames = report['frames'];
  final list =
      frames is List ? frames.take(maxCrashFrames).toList() : <Object?>[];
  return _crash(report, _base(report, 'java_exception', list));
}

Map<String, Object?> _base(
        Map<Object?, Object?> report, String source, List<Object?> frames) =>
    {
      'crash_id': report['crash_id'],
      'kind': 'native',
      'fatal': true,
      'name': truncateBytes('${report['name'] ?? 'unknown'}', 128),
      'message': truncateBytes('${report['message'] ?? ''}', maxCrashMessage),
      'source': {'signal', 'ns_exception', 'java_exception'}
              .contains(report['source'])
          ? report['source']
          : source,
      'frames': frames,
      'symbolicated': false,
    };

NativeCrash? _crash(
    Map<Object?, Object?> report, Map<String, Object?> properties) {
  final id = report['crash_id'];
  final millis = report['timestamp_ms'];
  if (id is! String || !uuidPattern.hasMatch(id) || millis is! num) return null;
  String? text(String key) =>
      report[key] is String ? report[key] as String : null;
  return NativeCrash(
    crashId: id,
    timestamp: DateTime.fromMillisecondsSinceEpoch(millis.toInt(), isUtc: true),
    properties: properties,
    appVersion: text('app_version'),
    build: text('build'),
    osVersion: text('os_version'),
    deviceModel: text('device_model'),
  );
}

/// Queues the crashes of earlier launches as `corlex.crash`, with their original time and the
/// versions of the run that crashed, then tells the native side to delete the files.
Future<void> sendPendingCrashes(CorlexClient client, CorlexPlatform platform,
    {bool Function()? isCurrent}) async {
  try {
    final binding = client.binding;
    if (binding != null && !await binding.select()) return;
    final scope = binding?.generation == null
        ? null
        : CrashScope(binding!.owner, binding.generation!,
            captureErrorMessages: client.options.captureErrorMessages);
    final pending = await platform.takePendingCrashes(scope: scope);
    bool active() =>
        (isCurrent?.call() ?? true) &&
        client.consent == ConsentState.granted &&
        (scope == null || binding?.generation == scope.generation);
    if (!active()) return;
    final discard = <String>{}, captured = <String, String>{};
    for (final item in pending) {
      if (!active()) return;
      final crash = parseNativeReport(client.device.os, item.data,
          captureErrorMessages: client.options.captureErrorMessages,
          scope: scope);
      if (crash == null) {
        discard.add(item.id);
        continue;
      }
      captured[item.id] = crash.crashId;
      client.capture(
        eventCrash,
        crash.properties,
        CaptureMeta(
          eventId: crash.crashId,
          timestamp: crash.timestamp,
          appVersion: crash.appVersion,
          build: crash.build,
          osVersion: crash.osVersion,
          deviceModel: crash.deviceModel,
        ),
      );
    }
    // The protected write is asynchronous: release valid files only after native readback.
    final durable = binding == null
        ? _legacyDurable(client, captured.values.toSet())
        : await binding.durableEvents(captured.values.toSet());
    final acknowledge = [
      ...discard,
      for (final entry in captured.entries)
        if (durable.contains(entry.value)) entry.key,
    ];
    if (acknowledge.isNotEmpty && active()) {
      await platform.ackCrashes(acknowledge, scope: scope);
    }
  } on Object {
    client.log('native_crash_read_failed');
  }
}

// Internal unbound clients retain the former JSON-lines queue, with positive disk readback too.
Set<String> _legacyDurable(CorlexClient client, Set<String> ids) {
  try {
    final file = File('${client.directory.path}/queue.jsonl');
    if (file.lengthSync() > maxQueueBytes) return {};
    return {
      for (final line in file.readAsLinesSync())
        if (jsonDecode(line) case {'event_id': final String id})
          if (ids.contains(id)) id,
    };
  } on Object {
    return {};
  }
}
