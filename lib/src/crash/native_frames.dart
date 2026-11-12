import '../limits.dart';
import 'privacy.dart';

final _address = RegExp(r'^0x[0-9a-fA-F]{1,16}$');
List<Map<String, Object?>> safeNativeFrames(Object? value) {
  if (value is! List) return [];
  return value.take(100).map(_frame).nonNulls.toList();
}

Map<String, Object?>? _frame(Object? value) {
  if (value is! Map) return null;
  final out = <String, Object?>{};
  if (value.containsKey('addr')) {
    final address = value['addr'];
    if (address is! String || !_address.hasMatch(address)) return null;
    out['addr'] = address;
    final id = value['debug_id'], base = value['image_addr'];
    if (id is String &&
        id.length == 36 &&
        uuidPattern.hasMatch(id) &&
        base is String &&
        _address.hasMatch(base)) {
      out['debug_id'] = id;
      out['image_addr'] = base;
    }
    final image = value['image'];
    if (image is String) {
      final safe = errorFile(image);
      if (safe != null) out['image'] = safe;
    }
  }
  final fn = value['fn'], file = value['file'];
  if (fn is String) {
    final safe = errorFunction(fn);
    if (safe != null) out['fn'] = safe;
  }
  if (file is String) {
    final safe = errorFile(file);
    if (safe != null) out['file'] = safe;
  }
  for (final key in ['line', 'col']) {
    final n = value[key];
    if (n is int && n >= 0 && n <= 9007199254740991) out[key] = n;
  }
  return out.isNotEmpty ? out : null;
}
