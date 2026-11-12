import 'evaluator.dart';

/// "Once per person and experiment in a session" (docs/experiments.md). A person is in the analysis
/// from the first `corlex.exposure` on; more of them add only noise, so the SDK sends one per
/// experiment per launch, however often the variant is read. The memory holds no id: the person is
/// a pair of 14-bit hashes of the experiment and the id.
class Exposures {
  final Set<String> _seen = {};

  /// True the first time this person is shown this experiment in this session.
  bool first(String experiment, String id) {
    final mark =
        '$experiment|${bucketOf('x1:$experiment', id)}.${bucketOf('x2:$experiment', id)}';
    return _seen.add(mark);
  }

  void clear() => _seen.clear();
}
