import '../limits.dart';
import 'privacy.dart';

const int maxCrashFrames = 100;
const int maxCrashMessage = 512;

final RegExp _frameLine = RegExp(r'^#\d+\s+(.*?)\s*\((.+)\)\s*$');
final RegExp _location = RegExp(r'^(.*?):(\d+)(?::(\d+))?$');

/// `[{fn, file, line, col}]` from the text of a Dart [StackTrace], innermost first, at most
/// [maxCrashFrames]. This is the shape the JS frames have, so the enricher groups and the API reads
/// them without a new case. Lines that are not frames (`<asynchronous suspension>`, the header of
/// an obfuscated trace, `package:stack_trace` separators) are skipped.
///
/// An obfuscated build (`--obfuscate --split-debug-info`) prints only offsets in the app's own
/// snapshot, which no line here matches: such a crash arrives without frames and is grouped by its
/// message. Symbolicating it is a follow-up (see README).
List<Map<String, Object?>> parseDartStack(String? trace) {
  if (trace == null) return const [];
  final frames = <Map<String, Object?>>[];
  for (final line in truncateBytes(trace, 64 * 1024).split('\n')) {
    if (frames.length == maxCrashFrames) break;
    final match = _frameLine.firstMatch(line.trim());
    if (match == null) continue;
    final frame = _frame(match.group(1)!, match.group(2)!);
    if (frame != null) frames.add(frame);
  }
  return frames;
}

Map<String, Object?>? _frame(String fn, String where) {
  final loc = _location.firstMatch(where);
  final file = errorFile(loc?.group(1) ?? where), name = errorFunction(fn);
  if (file == null && name == null) return null;
  final frame = <String, Object?>{
    if (name != null) 'fn': name,
    if (file != null) 'file': file,
  };
  final line = int.tryParse(loc?.group(2) ?? '');
  final col = int.tryParse(loc?.group(3) ?? '');
  if (line != null) frame['line'] = line;
  if (col != null) frame['col'] = col;
  return frame;
}

/// Error details are opt-in; known credentials/email/URL authentication are still removed.
String scrubMessage(String message) => detailedMessage(message);
