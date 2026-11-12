import Flutter
import UIKit

@main
@objc class AppDelegate: FlutterAppDelegate, FlutterImplicitEngineDelegate {
  override func application(
    _ application: UIApplication,
    didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    return super.application(application, didFinishLaunchingWithOptions: launchOptions)
  }

  func didInitializeImplicitFlutterEngine(_ engineBridge: FlutterImplicitEngineBridge) {
    GeneratedPluginRegistrant.register(with: engineBridge.pluginRegistry)
    registerCrashChannel(engineBridge.pluginRegistry)
  }

  /// The example's "native crash" buttons: an uncaught NSException or a fatal signal, which the
  /// Corlex plugin's reporter writes down and the next launch sends.
  private func registerCrashChannel(_ registry: FlutterPluginRegistry) {
    guard let registrar = registry.registrar(forPlugin: "ExampleCrash") else { return }
    let channel = FlutterMethodChannel(name: "example/crash", binaryMessenger: registrar.messenger())
    channel.setMethodCallHandler { call, result in
      result(nil)
      DispatchQueue.main.async {
        if (call.arguments as? String) == "signal" {
          raise(SIGSEGV)
        } else {
          NSException(name: NSExceptionName("ExampleNativeCrash"),
                      reason: "Native crash from the Corlex Flutter example", userInfo: nil).raise()
        }
      }
    }
  }
}
