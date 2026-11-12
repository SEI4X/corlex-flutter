import 'package:corlex_flutter/src/endpoint_policy.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test(
      'TLS policy preserves proxy paths and requires explicit external HTTP override',
      () {
    for (final url in [
      'https://example.test/proxy/cell',
      'http://localhost:3102/cell',
      'http://127.0.0.2',
      'http://[::1]',
      'http://10.0.2.2',
      'http://10.0.3.2'
    ]) {
      expect(EndpointPolicy.allowed(url, false), isTrue, reason: url);
    }
    expect(EndpointPolicy.allowed('http://192.168.1.5:3102/proxy', false),
        isFalse);
    expect(
        EndpointPolicy.allowed('http://192.168.1.5:3102/proxy', true), isTrue);
    for (final url in [
      'https://user:password@example.test',
      'https://@example.test',
      'https://example.test?x',
      'https://example.test#x',
      'ftp://example.test',
      'https://example.test:65536',
      'https://example.test:0',
      'https://example.test/\\n',
      r'https://example.test/\path'
    ]) {
      expect(EndpointPolicy.allowed(url, true), isFalse, reason: url);
    }
  });
}
