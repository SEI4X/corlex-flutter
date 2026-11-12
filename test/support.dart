import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:corlex_flutter/src/client.dart';
import 'package:corlex_flutter/src/http.dart';
import 'package:corlex_flutter/src/options.dart';
import 'package:corlex_flutter/src/platform.dart';
import 'package:corlex_flutter/src/storage.dart';
import 'package:corlex_flutter/src/binding/bridge.dart';
import 'binding_fixture.dart';

const String testKey = 'ck_test_0000000000000000000000000000000000000000000';

class Request {
  Request(this.method, this.url, this.body, this.headers);

  final String method;
  final Uri url;
  final String body;
  final Map<String, String> headers;

  List<Map<String, Object?>> get events =>
      ((jsonDecode(body) as Map)['events'] as List)
          .cast<Map<String, Object?>>();
}

/// The network: records every request and answers from [replies] (then [fallback]).
class FakeHttp implements Http {
  final List<Request> requests = [];
  final List<Object> replies = [];
  HttpReply fallback = const HttpReply(202);

  List<Request> get batches =>
      requests.where((r) => r.url.path == '/v1/batch').toList();

  Object _next() => replies.isEmpty ? fallback : replies.removeAt(0);

  Future<HttpReply> _answer() async {
    final next = _next();
    if (next is HttpReply) return next;
    throw next; // an exception: the network failed
  }

  @override
  Future<HttpReply> post(Uri url, String body, Map<String, String> headers) {
    requests.add(Request('POST', url, body, headers));
    return _answer();
  }

  @override
  Future<HttpReply> get(Uri url, Map<String, String> headers) {
    requests.add(Request('GET', url, '', headers));
    return _answer();
  }
}

class FakePlatform implements CorlexPlatform, StateBridgeProvider {
  final state = StateFixture();
  @override
  Future<StateBridge?> stateBridge() async => state;
  FakePlatform({this.info = iosInfo, this.tracking});

  static const DeviceInfo iosInfo = DeviceInfo(
    os: 'iOS',
    osVersion: '19.1',
    deviceModel: 'iPhone16,2',
    supportDir: '',
    appVersion: '1.4.2',
    build: '77',
  );
  static const DeviceInfo androidInfo = DeviceInfo(
    os: 'Android',
    osVersion: '15',
    deviceModel: 'Pixel 9',
    supportDir: '',
    appVersion: '2.0.0',
    build: '200',
  );

  final DeviceInfo info;
  String? tracking;
  final List<PendingCrash> pending = [];
  final List<bool> capture = [];
  final List<String> acked = [];
  bool wiped = false;

  @override
  Future<DeviceInfo> deviceInfo() async => info;

  @override
  Future<void> setCrashCapture(
      {required bool enabled, bool wipe = false, CrashScope? scope}) async {
    capture.add(enabled);
    if (wipe) wiped = true;
  }

  @override
  Future<List<PendingCrash>> takePendingCrashes({CrashScope? scope}) async =>
      List.of(pending);

  @override
  Future<void> ackCrashes(List<String> ids, {CrashScope? scope}) async {
    acked.addAll(ids);
    pending.removeWhere((c) => ids.contains(c.id));
  }

  @override
  Future<String?> trackingStatus() async => tracking;
}

class FakeTimer implements Timer {
  FakeTimer(this.delay, this.callback);

  final Duration delay;
  final void Function() callback;
  bool cancelled = false;
  bool fired = false;

  @override
  void cancel() => cancelled = true;

  @override
  bool get isActive => !cancelled && !fired;

  @override
  int get tick => 0;

  void fire() {
    if (!isActive) return;
    fired = true;
    callback();
  }
}

/// A client on a temp directory with a fake network and manual timers.
class Harness {
  Harness({
    CorlexOptions options = const CorlexOptions(),
    DeviceInfo device = FakePlatform.iosInfo,
    Directory? directory,
    ConsentState initial = ConsentState.granted,
  })  : dir = directory ?? Directory.systemTemp.createTempSync('corlex_test_'),
        http = FakeHttp() {
    client = CorlexClient(
      key: testKey,
      options: options,
      device: device,
      http: http,
      directory: dir,
      store: FileStore(dir),
      locale: () => 'en-US',
      timer: (delay, cb) {
        final timer = FakeTimer(delay, cb);
        timers.add(timer);
        return timer;
      },
    );
    client.start(client.storedConsent ?? initial);
  }

  final Directory dir;
  final FakeHttp http;
  late final CorlexClient client;
  final List<FakeTimer> timers = [];

  File get queueFile => File('${dir.path}/queue.jsonl');

  List<FakeTimer> get active => timers.where((t) => t.isActive).toList();

  /// The events in the queue file, as a restarted app would read them.
  List<Map<String, Object?>> get saved => queueFile.existsSync()
      ? queueFile
          .readAsLinesSync()
          .map((l) => jsonDecode(l) as Map<String, Object?>)
          .toList()
      : [];

  void dispose() {
    client.dispose();
    if (dir.existsSync()) dir.deleteSync(recursive: true);
  }
}
