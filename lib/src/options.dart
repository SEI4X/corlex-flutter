/// Where consent stands. `pending`: nothing is sent or written until `Corlex.optIn()`.
enum ConsentState { granted, pending, denied }

/// The consent a project starts with (services/ingest/docs/protocol.md section 4.1).
enum StartConsent {
  /// The app collects consent itself (default).
  granted,

  /// No network and no disk until `optIn()`.
  pending,

  /// iOS: follows App Tracking Transparency. The SDK reads the status and never shows the prompt.
  /// On Android it behaves as [granted].
  att,
}

/// Options of `Corlex.start`.
class CorlexOptions {
  const CorlexOptions({
    this.endpoint = 'https://ingest.corlex.ru',
    this.configEndpoint = 'https://config.corlex.ru',
    this.consent = StartConsent.granted,
    this.debug = false,
    this.allowInsecureHttp = false,
    this.batchSize = 20,
    this.flushInterval = const Duration(seconds: 5),
    this.configLive = false,
    this.configTimeout = const Duration(milliseconds: 1500),
    this.configEnabled = true,
    this.captureErrors = true,
    this.captureErrorMessages = false,
    this.captureLifecycle = true,
  });

  /// Ingest base URL.
  final String endpoint;

  /// Remote Config base URL (edge-config).
  final String configEndpoint;
  final StartConsent consent;

  /// Log what the SDK drops or retries (debugPrint).
  final bool debug;

  /// Explicit HTTP development override; derive this from the host app build.
  final bool allowInsecureHttp;

  /// Events per request, 1..500.
  final int batchSize;

  /// How long a partial batch waits.
  final Duration flushInterval;

  /// Apply a downloaded config at once instead of at the next launch.
  final bool configLive;

  /// How long `config.ready()` waits for the launch's download.
  final Duration configTimeout;

  /// `false` never downloads a config.
  final bool configEnabled;

  /// Dart errors (`FlutterError.onError`, `PlatformDispatcher.onError`) and native crashes as
  /// `corlex.crash`.
  final bool captureErrors;

  /// Explicit error detail opt-in. Caller data may still contain personal information.
  final bool captureErrorMessages;

  /// `app_open`, `app_background`, `app_foreground`.
  final bool captureLifecycle;
}
