import 'dart:convert';
import 'package:corlex_flutter/src/binding/digest.dart';
import 'package:corlex_flutter/src/binding/protocol.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:flutter_test/flutter_test.dart';
import 'support.dart' show testKey;

void main() {
  test('matches independent Node SHA256 tuples for canonical full URL paths',
      () {
    expect(
        bindingDigest(testKey,
            endpoint: 'https://EXAMPLE.com:443/a%2Fb/',
            configEndpoint: 'https://config.example///'),
        'aaec075d6da51d97d0c2adb0443f00233dcda1bfffaff7bb131d957ee3acc58b');
    expect(
        bindingDigest(testKey,
            endpoint: 'https://example.com/a%20b/😄/',
            configEndpoint: 'https://config.example/cell/'),
        '89cc404b6327d94563605380dd603a9edeb2ff36b87e8af0c194678a508396b0');
    expect(
        bindingDigest('cm_${'a' * 43}',
            endpoint: 'https://example.com',
            configEndpoint: 'https://example.com'),
        null);
  });
  test('privacy validates explicit SDK choice and exactly defined legacy shape',
      () {
    final p = Privacy.create(ConsentState.granted, ConsentState.denied);
    expect(Privacy.parse(p.raw)?.sdkChoice, ConsentState.granted);
    expect(
        Privacy.parse(
                jsonEncode({'generation': p.generation, 'state': 'denied'}))
            ?.sdkChoice,
        ConsentState.denied);
    expect(
        Privacy.parse(jsonEncode({
          'generation': p.generation,
          'state': 'granted',
          'sdkChoice': 'denied'
        })),
        null);
    expect(
        Privacy.parse(jsonEncode({
          'generation': p.generation,
          'state': 'granted',
          'extra': 'granted'
        })),
        null);
  });
  test('bounded state snapshot refuses foreign-owner rows before hydration',
      () {
    final p = Privacy.create(ConsentState.granted, ConsentState.granted);
    final text = jsonEncode({
      'privacy': p.raw,
      'rows': {'s:${'b' * 64}:${p.generation}:corlex_aid': 'foreign'}
    });
    expect(() => Snapshot.parse(text, 'a' * 64), throwsFormatException);
  });
}
