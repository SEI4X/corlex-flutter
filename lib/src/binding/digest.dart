import 'dart:convert';
import 'package:crypto/crypto.dart';
import '../endpoint_policy.dart';

String? bindingDigest(String key,
    {required String endpoint,
    required String configEndpoint,
    bool allowInsecureHttp = false}) {
  if (key.length != 51 ||
      !RegExp(r'^ck_(live|test)_[0-9A-Za-z]{43}$').hasMatch(key)) {
    return null;
  }
  if (!EndpointPolicy.allowed(endpoint, allowInsecureHttp) ||
      !EndpointPolicy.allowed(configEndpoint, allowInsecureHttp)) {
    return null;
  }
  String canonical(String text) {
    final uri = Uri.parse(text);
    final path = uri.path.replaceAll(RegExp(r'/+$'), '');
    final port = uri.hasPort && uri.port != (uri.scheme == 'https' ? 443 : 80)
        ? uri.port
        : null;
    return Uri(
            scheme: uri.scheme.toLowerCase(),
            host: uri.host.toLowerCase(),
            port: port,
            path: path)
        .toString();
  }

  return sha256
      .convert(utf8.encode(
          jsonEncode([key, canonical(endpoint), canonical(configEndpoint)])))
      .toString();
}
