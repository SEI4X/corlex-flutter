import 'package:flutter/services.dart';
import 'binding/bridge.dart';

/// What the host app is and where it may keep files.
class DeviceInfo {
  const DeviceInfo({
    required this.os,
    required this.osVersion,
    required this.deviceModel,
    required this.supportDir,
    this.appVersion,
    this.build,
  });

  factory DeviceInfo.fromMap(Map<Object?, Object?> map) => DeviceInfo(
        os: map['os'] as String? ?? 'unknown',
        osVersion: map['os_version'] as String? ?? '',
        deviceModel: map['device_model'] as String? ?? '',
        supportDir: map['support_dir'] as String? ?? '',
        appVersion: map['app_version'] as String?,
        build: map['build'] as String?,
      );

  /// `iOS` or `Android`.
  final String os;
  final String osVersion;
  final String deviceModel;

  /// `Application Support` (iOS) or `filesDir` (Android): private to the app.
  final String supportDir;

  /// `CFBundleShortVersionString` / `versionName`.
  final String? appVersion;

  /// `CFBundleVersion` / `versionCode` as a string.
  final String? build;

  /// The `context.platform` value: the native one, because the server symbolicates and groups by it.
  String get platform => os == 'iOS' ? 'ios' : 'android';
}

/// A crash file left by an earlier launch: [data] is the file's text as the native side wrote it.
class PendingCrash {
  const PendingCrash(this.id, this.data);

  final String id;
  final String data;
}

/// The thin native layer: device facts, the native crash reporter and the ATT status. Tests
/// replace it; the app uses [MethodChannelPlatform].
class CrashScope {
  const CrashScope(this.owner, this.generation,
      {this.captureErrorMessages = false});
  final bool captureErrorMessages;
  final String owner, generation;
}

abstract class CorlexPlatform {
  Future<DeviceInfo> deviceInfo();

  /// Turns the native crash handlers on or off. Off writes nothing; [wipe] deletes unsent reports.
  Future<void> setCrashCapture(
      {required bool enabled, bool wipe = false, CrashScope? scope});

  Future<List<PendingCrash>> takePendingCrashes({CrashScope? scope});

  /// Deletes reports that are queued now.
  Future<void> ackCrashes(List<String> ids, {CrashScope? scope});

  /// iOS: `notDetermined`, `authorized`, `denied` or `restricted`; null elsewhere. Reading the
  /// status needs no permission; the SDK never shows the prompt.
  Future<String?> trackingStatus();
}

class MethodChannelPlatform implements CorlexPlatform, StateBridgeProvider {
  static const MethodChannel _channel = MethodChannel('ru.corlex/flutter');

  @override
  Future<StateBridge?> stateBridge() => MethodStateBridge.open(_channel);
  @override
  Future<DeviceInfo> deviceInfo() async {
    final map = await _channel.invokeMapMethod<Object?, Object?>('deviceInfo');
    return DeviceInfo.fromMap(map ?? const {});
  }

  @override
  Future<void> setCrashCapture(
          {required bool enabled, bool wipe = false, CrashScope? scope}) =>
      _channel.invokeMethod<void>('setCrashCapture', {
        'enabled': enabled,
        'wipe': wipe,
        'owner': scope?.owner,
        'generation': scope?.generation,
        'captureErrorMessages': scope?.captureErrorMessages ?? false
      });

  @override
  Future<List<PendingCrash>> takePendingCrashes({CrashScope? scope}) async {
    final items = await _channel.invokeListMethod<Map<Object?, Object?>>(
        'takePendingCrashes',
        {'owner': scope?.owner, 'generation': scope?.generation});
    return [
      for (final item in items ?? const <Map<Object?, Object?>>[])
        if (item['id'] is String && item['data'] is String)
          PendingCrash(item['id']! as String, item['data']! as String),
    ];
  }

  @override
  Future<void> ackCrashes(List<String> ids, {CrashScope? scope}) =>
      _channel.invokeMethod<void>('ackCrashes',
          {'ids': ids, 'owner': scope?.owner, 'generation': scope?.generation});

  @override
  Future<String?> trackingStatus() =>
      _channel.invokeMethod<String>('trackingStatus');
}
