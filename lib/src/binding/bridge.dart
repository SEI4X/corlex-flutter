import 'dart:io';
import 'dart:convert';
import 'package:flutter/services.dart';

abstract interface class StateBridge {
  /// Only the bounded authoritative SDK privacy sidecar, never captured rows.
  String? current();
  Future<String> fresh();
  Future<String> read(String owner);
  Future<String> exchange(String command);
  Future<String> revoke(String expected, String record);
  Future<String> observe(String expected, String ceiling);
  Future<void> select(String owner, String generation);
}

abstract interface class StateBridgeProvider {
  Future<StateBridge?> stateBridge();
}

class MethodStateBridge implements StateBridge {
  MethodStateBridge._(this.channel, this.path);
  final MethodChannel channel;
  final String path;
  static Future<StateBridge?> open(MethodChannel channel) async {
    try {
      final info =
          await channel.invokeMapMethod<String, Object?>('bindingInfo');
      final path = info?['privacyPath'];
      if (info?['protectedStorage'] != 2 ||
          path is! String ||
          !path.endsWith('/privacy.json')) {
        return null;
      }
      return MethodStateBridge._(channel, path);
    } on Object {
      return null;
    }
  }

  @override
  String? current() {
    try {
      final file = File(path);
      if (!file.existsSync()) return '';
      final handle = file.openSync();
      try {
        final bytes = handle.readSync(257);
        return bytes.length <= 256 ? utf8.decode(bytes) : null;
      } finally {
        handle.closeSync();
      }
    } on Object {
      return null;
    }
  }

  @override
  Future<String> fresh() async =>
      await channel.invokeMethod<String>('currentSdkPrivacy') ?? '';
  @override
  Future<String> read(String owner) async =>
      await channel
          .invokeMethod<String>('readBoundSdkState', {'owner': owner}) ??
      '';
  @override
  Future<String> exchange(String command) async =>
      await channel
          .invokeMethod<String>('exchangeSdkState', {'command': command}) ??
      '';
  @override
  Future<String> revoke(String expected, String record) async =>
      await channel.invokeMethod<String>(
          'revokeSdkPrivacy', {'expected': expected, 'record': record}) ??
      '';
  @override
  Future<String> observe(String expected, String ceiling) async =>
      await channel.invokeMethod<String>(
          'observeSdkCeiling', {'expected': expected, 'ceiling': ceiling}) ??
      '';
  @override
  Future<void> select(String owner, String generation) =>
      channel.invokeMethod<void>(
          'selectSdkScope', {'owner': owner, 'generation': generation});
}
