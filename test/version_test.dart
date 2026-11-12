import 'dart:io';

import 'package:corlex_flutter/src/version.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('sdkVersion, pubspec.yaml and the iOS podspec are one version', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(
      RegExp(r'^version: (\S+)', multiLine: true).firstMatch(pubspec)![1],
      sdkVersion,
    );
    final podspec = File('ios/corlex_flutter.podspec').readAsStringSync();
    expect(
      RegExp(r"s\.version\s*=\s*'([^']+)'").firstMatch(podspec)![1],
      sdkVersion,
    );
  });
}
