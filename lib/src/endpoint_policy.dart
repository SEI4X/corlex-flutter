/// HTTP is limited to loopback/emulators unless the host explicitly opts into development HTTP.
abstract final class EndpointPolicy {
  static bool allowed(String value, bool allowInsecureHttp) {
    if (value.codeUnits.any((c) => c <= 32 || c == 127) ||
        value.contains(r'\')) {
      return false;
    }
    final authority = RegExp(r'^[A-Za-z][A-Za-z0-9+.-]*://([^/?#]*)')
        .firstMatch(value)
        ?.group(1);
    if (authority == null || authority.contains('@')) return false;
    final uri = Uri.tryParse(value);
    if (uri == null ||
        !uri.hasAuthority ||
        uri.host.isEmpty ||
        uri.authority.contains('@') ||
        uri.hasQuery ||
        uri.hasFragment) {
      return false;
    }
    if (uri.port < 1 || uri.port > 65535) return false;
    if (uri.scheme == 'https') return true;
    if (uri.scheme != 'http') return false;
    final host = uri.host.toLowerCase();
    final ipv4 = host.split('.');
    final loopback = ipv4.length == 4 &&
        ipv4.every((s) =>
            int.tryParse(s) != null &&
            int.parse(s) >= 0 &&
            int.parse(s) <= 255) &&
        ipv4.first == '127';
    return allowInsecureHttp ||
        loopback ||
        host == 'localhost' ||
        host == '::1' ||
        host == '10.0.2.2' ||
        host == '10.0.3.2';
  }
}
