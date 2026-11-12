import Foundation

enum ProtectedStateReply { case value(Any?), unhandled }
enum ProtectedStateError: Error { case invalid }

/// Native state wire adapter only. Reporter callbacks never re-enter the state helper lock.
final class ProtectedStateChannel {
    private let state: CorlexFlutterStateStore
    private let privacyPath: String
    private let disableReporter: () -> Void
    private let crashes: CorlexNativeCrashAccess
    init(state: CorlexFlutterStateStore, privacyPath: String, disableReporter: @escaping () -> Void) {
        self.state = state; self.privacyPath = privacyPath; self.disableReporter = disableReporter
        self.crashes = CorlexNativeCrashAccess(state: state)
    }
    func call(_ method: String, arguments args: [String: Any]) throws -> ProtectedStateReply {
        switch method {
        case "bindingInfo":
            _ = try state.currentPrivacy()
            return .value(["protectedStorage": 2, "privacyPath": privacyPath, "crashBinding": 1])
        case "currentSdkPrivacy": return .value(try state.currentPrivacy())
        case "readBoundSdkState": return .value(try state.readBound(text(args, "owner")))
        case "exchangeSdkState": return .value(try state.exchange(text(args, "command"), beforePublish: disable))
        case "revokeSdkPrivacy":
            return .value(try state.revoke(text(args, "record"), expected: text(args, "expected"), beforePublish: disable))
        case "observeSdkCeiling": return .value(try state.observe(text(args, "expected"), ceiling: text(args, "ceiling"), beforePublish: disable))
        case "selectSdkScope":
            try state.selectScope(text(args, "owner"), text(args, "generation"), beforeChange: disable)
            return .value(nil)
        case "setCrashCapture":
            try crashes.set(args)
            return .value(nil)
        case "takePendingCrashes": return .value(try crashes.pending(args))
        case "ackCrashes": try crashes.ack(args); return .value(nil)
        default: return .unhandled
        }
    }
    private func disable() { crashes.disable(); disableReporter() }
    private func text(_ args: [String: Any], _ key: String) throws -> String {
        guard let value = args[key] as? String else { throw ProtectedStateError.invalid }
        return value
    }
}
