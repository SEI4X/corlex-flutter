import 'dart:convert';
import 'dart:io';

import 'package:corlex_flutter/src/limits.dart';
import 'package:corlex_flutter/src/queue.dart';
import 'package:flutter_test/flutter_test.dart';

WireEvent event(String id) =>
    {'event_id': id, 'name': 'e', 'properties': <String, Object?>{}};

void main() {
  late Directory dir;
  late File file;
  setUp(() {
    dir = Directory.systemTemp.createTempSync('corlex_queue_');
    file = File('${dir.path}/corlex/queue.jsonl');
  });
  tearDown(() => dir.deleteSync(recursive: true));

  test('events survive a restart, in order', () {
    final queue = EventQueue(file)
      ..push(event('a'))
      ..push(event('b'));
    expect(queue.size, 2);
    final again = EventQueue(file);
    expect(again.peek(10).map((e) => e['event_id']), ['a', 'b']);
  });

  test('drop removes exactly the delivered batch and rewrites the file', () {
    final queue = EventQueue(file)
      ..push(event('a'))
      ..push(event('b'))
      ..push(event('c'));
    queue.drop([event('a'), event('b')]);
    expect(queue.peek(10).map((e) => e['event_id']), ['c']);
    expect(EventQueue(file).size, 1);
  });

  test('the oldest events go first when more than 1000 are queued', () {
    final queue = EventQueue(file);
    for (var i = 0; i < maxQueue + 5; i++) {
      queue.push(event('e$i'));
    }
    expect(queue.size, maxQueue);
    expect(queue.peek(1).single['event_id'], 'e5');
    expect(EventQueue(file).size, maxQueue);
  });

  test('a damaged or half-written line is skipped', () {
    file.parent.createSync(recursive: true);
    file.writeAsStringSync(
        '${jsonEncode(event('a'))}\n{"event_id":"b","na\n[1,2]\n${jsonEncode(event('c'))}\n');
    expect(EventQueue(file).peek(10).map((e) => e['event_id']), ['a', 'c']);
  });

  test('without a file nothing touches the disk until persistence is enabled',
      () {
    final queue = EventQueue(null)..push(event('a'));
    expect(file.existsSync(), isFalse);
    queue.enablePersistence(file);
    expect(EventQueue(file).size, 1);
  });

  test('clear deletes the file; has finds queued ids', () {
    final queue = EventQueue(file)..push(event('a'));
    expect(queue.has('a'), isTrue);
    queue.clear();
    expect(queue.has('a'), isFalse);
    expect(file.existsSync(), isFalse);
  });
}
