import Foundation

/// State I/O stays off the UI thread; privacy admission must bypass blocked ordinary reads.
final class CorlexFlutterDispatch {
    /// No state/reporter lock or SDK IO has started when registration calls this main-only hook.
    @discardableResult
    static func prepareMainThreadStack() -> Bool {
        if Thread.isMainThread { return corlex_crash_prepare_thread_stack() == 1 }
        return DispatchQueue.main.sync { corlex_crash_prepare_thread_stack() == 1 }
    }

    private let state = DispatchQueue(label: "ru.corlex.flutter.state", qos: .utility)
    private let privacy = DispatchQueue(label: "ru.corlex.flutter.privacy", qos: .utility, attributes: .concurrent)
    private let privacyMethods: Set<String> = ["revokeSdkPrivacy", "observeSdkCeiling", "exchangeSdkState", "currentSdkPrivacy"]
    func submit(_ method: String, arguments: [String: Any], operation: @escaping () -> Void) {
        let refusal = method == "setCrashCapture" && arguments["enabled"] as? Bool != true
        let queue = privacyMethods.contains(method) || refusal ? privacy : state
        queue.async(execute: operation)
    }
}
