import 'dart:convert';
import 'dart:io';

import 'package:corlex_flutter/src/config/evaluator.dart';
import 'package:flutter_test/flutter_test.dart';

/// The shared vectors every SDK must pass (`packages/domain/test-vectors/remote-config.json`):
/// the TypeScript evaluator and the Go reference run the same file. They are read from the
/// monorepo, not copied, so they cannot drift.
Map<String, Object?> loadVectors() {
  final file = File('test/fixtures/remote-config.json');
  return jsonDecode(file.readAsStringSync()) as Map<String, Object?>;
}

List<Map<String, Object?>> list(Object? value) =>
    (value! as List).cast<Map<String, Object?>>();

void main() {
  final vectors = loadVectors();

  test('the vectors file is where the test expects it', () {
    expect(vectors['description'], isNotNull);
    expect(list(vectors['buckets']), isNotEmpty);
  });

  test('bucketOf matches every vector (unicode, NUL, empty, 256 chars)', () {
    for (final v in list(vectors['buckets'])) {
      expect(
        bucketOf(v['key']! as String, v['userId']! as String),
        v['bucket'],
        reason: '${v['key']} / ${v['userId']}',
      );
    }
  });

  test('the bucket series matches', () {
    final s = (vectors['series']! as Map).cast<String, Object?>();
    final expected = (s['buckets']! as List).cast<int>();
    expect(expected.length, s['count']);
    for (var i = 0; i < expected.length; i++) {
      expect(bucketOf(s['key']! as String, '${s['prefix']}$i'), expected[i],
          reason: '${s['key']} $i');
    }
  });

  test('resolveParam matches every vector', () {
    final cases = list(vectors['resolve']);
    expect(cases.length, greaterThan(10));
    for (final c in cases) {
      final context = (c['context']! as Map).cast<String, Object?>();
      final platform = context['platform'] as String?;
      final resolved = resolveParam(
        (c['param']! as Map).cast<String, Object?>(),
        context['userId']! as String,
        [if (platform != null) platform],
      );
      final expected = c['expected'] as Map?;
      if (expected == null) {
        expect(resolved, isNull, reason: '${c['name']}');
      } else {
        expect(resolved, isNotNull, reason: '${c['name']}');
        expect(resolved!.value, expected['value'], reason: '${c['name']}');
      }
    }
  });

  test('assignVariant matches every vector', () {
    final cases = list(vectors['experiments']);
    expect(cases.length, greaterThan(10));
    for (final c in cases) {
      final got = assignVariant(
        (c['experiment']! as Map).cast<String, Object?>(),
        c['userId']! as String,
      );
      final expected = (c['expected']! as Map).cast<String, Object?>();
      expect(got, isNotNull, reason: '${c['name']}');
      expect(got!.variant, expected['variant'], reason: '${c['name']}');
      expect(got.index, expected['index'], reason: '${c['name']}');
      expect(got.value, expected['value'], reason: '${c['name']}');
    }
  });

  test('the experiment series matches', () {
    final s = (vectors['experimentSeries']! as Map).cast<String, Object?>();
    final experiment = (s['experiment']! as Map).cast<String, Object?>();
    final expected = (s['variants']! as List).cast<int>();
    expect(expected.length, s['count']);
    for (var i = 0; i < expected.length; i++) {
      final got = assignVariant(experiment, '${s['prefix']}$i');
      expect(got?.index, expected[i], reason: '${experiment['k']} $i');
    }
  });

  test('a flutter override beats the native platform override', () {
    final param = {
      'k': 'x',
      't': 'bool',
      'v': false,
      'r': 0,
      'o': {'ios': true, 'flutter': 'f'},
    };
    expect(resolveParam(param, 'u', ['flutter', 'ios'])!.value, 'f');
    expect(resolveParam(param, 'u', ['ios'])!.value, true);
    expect(resolveParam(param, 'u', ['android']), isNull);
  });
}
