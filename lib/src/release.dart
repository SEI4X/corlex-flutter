import 'limits.dart';

/// Release identity must remain exact; clipping can attach a crash to another build.
String exactRelease(String? value, int maxBytes) {
  if (value == null ||
      value.isEmpty ||
      value.length > maxBytes ||
      byteLength(value) > maxBytes) {
    return '';
  }
  final units = value.codeUnits;
  for (var i = 0; i < units.length; i++) {
    final c = units[i];
    if (c >= 0xd800 && c <= 0xdbff) {
      if (++i >= units.length || units[i] < 0xdc00 || units[i] > 0xdfff) {
        return '';
      }
    } else if (c >= 0xdc00 && c <= 0xdfff) {
      return '';
    }
  }
  return value;
}
