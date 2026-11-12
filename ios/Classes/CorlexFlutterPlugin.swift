import AppTrackingTransparency
import Flutter
import UIKit

/// What describes this device and build. No advertising id, no vendor id, no device name: only the
/// model identifier, the OS version and the app's own version.
struct DeviceFacts {
    var appVersion: String?
    var build: String?
    var osVersion: String
    var deviceModel: String

    static func current(bundle: Bundle = .main) -> DeviceFacts {
        let info = bundle.infoDictionary
        let v = ProcessInfo.processInfo.operatingSystemVersion
        let base = "\(v.majorVersion).\(v.minorVersion)"
        return DeviceFacts(
            appVersion: info?["CFBundleShortVersionString"] as? String,
            build: info?["CFBundleVersion"] as? String,
            osVersion: v.patchVersion > 0 ? "\(base).\(v.patchVersion)" : base,
            deviceModel: modelIdentifier()
        )
    }

    /// `iPhone16,2`. In the simulator the model it pretends to be.
    static func modelIdentifier() -> String {
        #if targetEnvironment(simulator)
        if let model = ProcessInfo.processInfo.environment["SIMULATOR_MODEL_IDENTIFIER"] { return model }
        #endif
        var system = utsname()
        uname(&system)
        return withUnsafeBytes(of: &system.machine) { String(decoding: $0.prefix { $0 != 0 }, as: UTF8.self) }
    }

    static var architecture: String {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }
}

/// The thin native layer of the Corlex Flutter SDK: device facts, the native crash reporter and the
/// ATT status. Everything else (events, queue, Remote Config) is Dart.
public class CorlexFlutterPlugin: NSObject, FlutterPlugin {
    public static func register(with registrar: FlutterPluginRegistrar) {
        CorlexFlutterDispatch.prepareMainThreadStack()
        let channel = FlutterMethodChannel(name: "ru.corlex/flutter", binaryMessenger: registrar.messenger())
        registrar.addMethodCallDelegate(CorlexFlutterPlugin(), channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        let args = call.arguments as? [String: Any]
        switch call.method {
        case "deviceInfo":
            result(Self.deviceInfo())
        case "trackingStatus":
            result(Self.trackingStatus())
        default:
            Self.worker.submit(call.method, arguments: args ?? [:]) {
                do {
                    guard let channel = Self.protectedState else { throw ProtectedStateError.invalid }
                    let reply = try channel.call(call.method, arguments: args ?? [:])
                    DispatchQueue.main.async {
                        switch reply { case .value(let value): result(value); case .unhandled: result(FlutterMethodNotImplemented) }
                    }
                } catch {
                    DispatchQueue.main.async { result(FlutterError(code: "corlex_native_unavailable", message: "Corlex protected SDK operation is unavailable.", details: nil)) }
                }
            }
        }
    }

    private static let worker = CorlexFlutterDispatch()
    private static let protectedState: ProtectedStateChannel? = {
        guard let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first else { return nil }
        let path = support.appendingPathComponent("CorlexFlutter/sdk-state/privacy.json").path
        return ProtectedStateChannel(state: .shared, privacyPath: path) {
            CorlexCrashCapture.shared.setEnabled(false, wipe: false)
        }
    }()

    private static func deviceInfo() -> [String: Any] {
        let facts = DeviceFacts.current()
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        try? FileManager.default.createDirectory(at: support, withIntermediateDirectories: true)
        var info: [String: Any] = [
            "os": "iOS", "os_version": facts.osVersion, "device_model": facts.deviceModel,
            "support_dir": support.path,
        ]
        if let version = facts.appVersion { info["app_version"] = version }
        if let build = facts.build { info["build"] = build }
        return info
    }

    /// Reading the status needs no permission and never shows the prompt.
    private static func trackingStatus() -> String {
        switch ATTrackingManager.trackingAuthorizationStatus {
        case .authorized: return "authorized"
        case .denied: return "denied"
        case .restricted: return "restricted"
        case .notDetermined: return "notDetermined"
        @unknown default: return "notDetermined"
        }
    }
}
