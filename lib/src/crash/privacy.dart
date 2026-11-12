import '../limits.dart';

final _credential = RegExp(
    r'(?:ck_(?:live|test)_|cm_|corlex_up_|sk_)[A-Za-z0-9_-]{8,}|\bAKIA[A-Z0-9]{16}\b|\beyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+',
    caseSensitive: false);
final _email =
    RegExp(r'[A-Z0-9._%+-]+@[A-Z0-9.-]+\.[A-Z]{2,}', caseSensitive: false);
bool sensitiveLabel(String value) =>
    _credential.hasMatch(value) || _email.hasMatch(value);
String errorType(String value, {String fallback = 'Error'}) =>
    !sensitiveLabel(value) &&
            RegExp(r'^[A-Za-z_$][A-Za-z0-9_.$]{0,127}$').hasMatch(value)
        ? value
        : fallback;
String? errorFunction(String value) => !sensitiveLabel(value) &&
        RegExp(r'^[A-Za-z_$][A-Za-z0-9_.$<> ]{0,255}$').hasMatch(value)
    ? value
    : null;
String? errorFile(String value) {
  if (sensitiveLabel(value) || value.length > 4096) return null;
  try {
    final uri = Uri.tryParse(value);
    if (uri != null && uri.userInfo.isNotEmpty) return null;
    if ((value.startsWith('package:') || value.startsWith('dart:')) &&
        RegExp(r'^[A-Za-z0-9_./:-]+$').hasMatch(value)) {
      return value;
    }
    final path = (uri?.path ?? value).replaceAll('\\', '/');
    final name = path.split('/').last;
    return !sensitiveLabel(name) &&
            RegExp(r'^[A-Za-z0-9_.-]{1,128}$').hasMatch(name)
        ? name
        : null;
  } on Object {
    return null;
  }
}

String detailedMessage(String message) {
  var clean = message
      .replaceAll(_credential, '[credential]')
      .replaceAll(_email, '[email]');
  clean = clean.replaceAll(
      RegExp(r'Bearer\s+\S+', caseSensitive: false), 'Bearer [credential]');
  clean = clean.replaceAllMapped(RegExp(r'(?:https?|wss?)://[^\s]+'), (m) {
    final uri = Uri.tryParse(m.group(0) ?? '');
    return uri == null
        ? '[url]'
        : Uri(
                scheme: uri.scheme,
                host: uri.host,
                port: uri.hasPort ? uri.port : null,
                path: uri.path)
            .toString();
  }).replaceAll(RegExp(r'(/Users|/home)/[^/\s]+/'), '~/');
  return truncateBytes(clean, 512);
}
