import 'package:corlex_flutter/src/platform.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('ru.corlex/flutter');
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  tearDown(() => messenger.setMockMethodCallHandler(channel, null));
  for (final details in [false, true]) {
    test(
        'native capture receives immutable scope and explicit details=$details',
        () async {
      MethodCall? received;
      messenger.setMockMethodCallHandler(channel, (call) async {
        received = call;
        return null;
      });
      final scope = CrashScope('a' * 64, '12345678-1234-1234-1234-123456789abc',
          captureErrorMessages: details);
      await MethodChannelPlatform()
          .setCrashCapture(enabled: true, scope: scope);
      expect(received?.method, 'setCrashCapture');
      expect(received?.arguments, {
        'enabled': true,
        'wipe': false,
        'owner': scope.owner,
        'generation': scope.generation,
        'captureErrorMessages': details
      });
    });
  }
}
