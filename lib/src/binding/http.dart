import 'dart:io';
import '../http.dart';
import '../options.dart';
import 'driver.dart';

/// Current native privacy is checked immediately before every SDK request and after its reply.
class BoundHttp implements Http, ConsentAwareHttp {
  BoundHttp(this.inner, this.binding);
  final Http inner;
  final BindingDriver binding;
  bool _paused = true;
  @override
  void pause() {
    _paused = true;
    pauseHttp(inner);
  }

  @override
  void resume() {
    _paused = false;
    resumeHttp(inner);
  }

  Future<HttpReply> _request(Future<HttpReply> Function() perform) async {
    if (_paused || !await binding.fresh()) {
      throw const HttpException('sdk_permission_pending');
    }
    final generation = binding.generation;
    final response = await perform();
    if (_paused ||
        binding.consent != ConsentState.granted ||
        binding.generation != generation) {
      throw const HttpException('sdk_request_superseded');
    }
    return response;
  }

  @override
  Future<HttpReply> get(Uri url, Map<String, String> headers) =>
      _request(() => inner.get(url, headers));
  @override
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers) =>
      _request(() => inner.post(url, body, headers));
}
