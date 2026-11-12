# Corlex for Flutter

Version 0.1.0 is an unpublished SDK-only source candidate. Stable package/tag publication and owner merge are separate release gates. The Corlex application/server and its private Git history are not part of this repository.

## Installation

From a reviewed checkout run `flutter pub add corlex_flutter --path ../corlex-flutter`. Then pub get and rebuild the native app; hot reload cannot register the plugin. No pub.dev publication is assumed.

Use the project's actual ingest/config URLs. The write-only project SDK key is compiled into the client; it is observable in an app bundle. MCP, upload and AI-provider secrets must never be embedded in an app. Corlex MCP onboarding can provision the SDK key directly into ignored build configuration.

## Quick start

The variables below come from your host app's ignored build configuration/project setup; they are not literal placeholder services.

```dart
await Corlex.start(
  const String.fromEnvironment("CORLEX_KEY"),
  options: CorlexOptions(endpoint: ingestUrl, configEndpoint: configUrl, consent: StartConsent.pending),
);
// After the host app has obtained the applicable consent:
Corlex.optIn();
Corlex.track("signup_completed", {"method": "email"});
```

Call startup once. Never copy another analytics pipeline merely to obtain native upload tools. reset rotates identity; historical events retain their captured identities. optOut withdraws collection and clears pending SDK state.

## Features and API

Await `Corlex.start(key, options: ...)` before runApp; `track`, `identify`, `setUserProperties`, `screen`, `reset`, async `flush`, `optIn`, `optOut`, `consent`, `flag`, `experiment`; `Corlex.config.get/getAll/ready/refresh/onUpdate`.

Automatic lifecycle and screen events, explicit product events, consent, offline delivery, crash reports, Remote Config and deterministic experiments are described in [API](docs/API.md), [data/consent](docs/CONSENT-AND-DATA.md), [storage](docs/LOCAL-STORAGE.md) and [crashes](docs/CRASHES.md).

## Development

Flutter 3.41.6 stable (framework db50e20168db8fee486b9abf32fc912de3bc5b6a / Dart 3.11.4 tested). `flutter pub get`; `flutter analyze`; `flutter test`; from example, `flutter build apk --release` and `flutter build ios --simulator --no-codesign` on macOS. Native physical probes: `scripts/test-state.sh`, `scripts/test-channel.sh`, `scripts/test-crash.sh`; verify standalone provenance with `python3 scripts/verify-state.py` and `scripts/check-native-copies.sh`. Run the unchanged synthetic MethodChannel/HTTP case with `scripts/test-integration.sh <simulator-or-device-id>`; it creates and removes an owned temporary consumer with pinned test-only dependencies. The shipped example excludes integration_test, so release registration matches its classpath.

See [troubleshooting](docs/TROUBLESHOOTING.md), [security](SECURITY.md), [contributing](CONTRIBUTING.md), [release process](docs/PUBLISHING.md) and [changelog](CHANGELOG.md). MIT covers our SDK code; bundled third-party tools/dependencies keep their own licenses/notices.
