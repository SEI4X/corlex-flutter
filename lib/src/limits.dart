import 'dart:convert';
import 'dart:math';

// Mirrors services/ingest/internal/event/validate.go and docs/protocol.md (and sdk-core/limits.ts).
const int maxName = 128;
const int maxId = 256;
const int maxProperties = 100;
const int maxPropertyKey = 128;
const int maxPropertyString = 1024;
const int maxArray = 100;
const int maxDepth = 4;
const int maxBatchEvents = 500;
const int maxEventBytes = 32768;
const int maxQueue = 1000;

/// Reserved events (services/ingest/docs/protocol.md section 4).
const String eventIdentify = 'corlex.identify';
const String eventUserProps = 'corlex.user_props';
const String eventExposure = 'corlex.exposure';
const String eventCrash = 'corlex.crash';

final RegExp namePattern = RegExp(r'^[a-z0-9_.:-]{1,128}$');
final RegExp uuidPattern = RegExp(
  r'^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$',
  caseSensitive: false,
);

/// Size of [text] in UTF-8, as the server counts it.
int byteLength(String text) => utf8.encode(text).length;

/// Cuts [text] to at most [max] UTF-8 bytes without splitting a character.
String truncateBytes(String text, int max) {
  if (text.length * 3 <= max || byteLength(text) <= max) return text;
  var bytes = 0;
  final out = StringBuffer();
  for (final rune in text.runes) {
    final size = rune < 0x80
        ? 1
        : rune < 0x800
            ? 2
            : rune < 0x10000
                ? 3
                : 4;
    if (bytes + size > max) break;
    bytes += size;
    out.writeCharCode(rune);
  }
  return out.toString();
}

final Random _random = Random.secure();

/// A random UUID v4. Ids only have to be unique; the SDK never uses a device or advertising id.
String newUuid([Random? random]) {
  final r = random ?? _random;
  final b = List<int>.generate(16, (_) => r.nextInt(256));
  b[6] = (b[6] & 0x0f) | 0x40;
  b[8] = (b[8] & 0x3f) | 0x80;
  final h = b.map((x) => x.toRadixString(16).padLeft(2, '0')).join();
  return '${h.substring(0, 8)}-${h.substring(8, 12)}-${h.substring(12, 16)}-'
      '${h.substring(16, 20)}-${h.substring(20)}';
}
