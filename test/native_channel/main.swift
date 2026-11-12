import Foundation

func check(_ value: Bool, _ message: String = "native channel assertion failed") { precondition(value, message) }
// The production registration hook hops to main before any state/reporter lock or path exists.
let prepared = DispatchSemaphore(value: 0)
var prepareSucceeded = false
DispatchQueue.global().async { prepareSucceeded = CorlexFlutterDispatch.prepareMainThreadStack(); prepared.signal() }
let prepareDeadline = Date().addingTimeInterval(3)
while prepared.wait(timeout: .now()) != .success {
    check(Date() < prepareDeadline, "worker registration main hop deadlocked")
    _ = RunLoop.current.run(mode: .default, before: Date().addingTimeInterval(0.01))
}
check(prepareSucceeded, "registration attempted alternate-stack preparation on worker")
var stack = stack_t()
check(sigaltstack(nil, &stack) == 0 && stack.ss_flags & SS_DISABLE == 0 && stack.ss_sp != nil)
check(corlex_crash_open_report() < 0, "stack preparation armed capture before consent")
print("Production registration: worker-to-main alternate-stack preparation without arming capture")
let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-native-channel-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let privacyFile = root.appendingPathComponent("privacy.json")
let store = CorlexFlutterStateStore(directory: root)
var observations: [String] = []
let channel = ProtectedStateChannel(state: store, privacyPath: privacyFile.path) {
    observations.append((try? String(contentsOf: privacyFile, encoding: .utf8)) ?? "")
}
func value(_ method: String, _ args: [String: Any] = [:]) throws -> Any? {
    switch try channel.call(method, arguments: args) {
    case .value(let result): return result
    case .unhandled: fatalError("native method missing")
    }
}
func encoded(_ input: [String: Any]) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
}
func record(_ state: String, choice: String? = nil) throws -> String {
    try encoded(["generation": UUID().uuidString.lowercased(), "state": state, "sdkChoice": choice ?? state])
}
func object(_ input: Any?) throws -> [String: Any] {
    try JSONSerialization.jsonObject(with: Data((input as! String).utf8)) as! [String: Any]
}
let owner = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
let info = try value("bindingInfo") as! [String: Any]
check(info["protectedStorage"] as? Int == 2 && info["privacyPath"] as? String == privacyFile.path)
check(info["crashBinding"] as? Int == 1, "proved scoped native capture was not advertised")
check(try value("currentSdkPrivacy") as? String == "")
let grant = try record("granted")
_ = try value("exchangeSdkState", ["command": encoded(["owner": owner, "expected": "", "privacy": grant])])
check(observations == [""], "reporter was not disabled before first publication")
let generation = try object(grant)["generation"] as! String
_ = try value("exchangeSdkState", ["command": encoded(["owner": owner, "expected": grant, "generation": generation, "changes": ["corlex_aid": "synthetic_aid"]])])
let rows = try object(value("readBoundSdkState", ["owner": owner]))["rows"] as! [String: String]
check(rows["s:\(owner):\(generation):corlex_aid"] == "synthetic_aid")
check(try (object(value("readBoundSdkState", ["owner": other]))["rows"] as! [String: String]).isEmpty)
_ = try value("selectSdkScope", ["owner": owner, "generation": generation])
let deniedAtt = try value("observeSdkCeiling", ["expected": grant, "ceiling": "denied"]) as! String
check(try object(deniedAtt)["state"] as? String == "denied")
check(try object(deniedAtt)["sdkChoice"] as? String == "granted")
check(observations.last == grant, "reporter callback happened after publication")
let denial = try record("denied")
check(try value("revokeSdkPrivacy", ["expected": grant, "record": denial]) as? String == deniedAtt)
check(try value("revokeSdkPrivacy", ["expected": deniedAtt, "record": denial]) as? String == denial)
_ = try value("exchangeSdkState", ["command": encoded(["owner": owner, "expected": grant, "privacy": record("granted")])])
check(try value("currentSdkPrivacy") as? String == denial, "stale channel CAS overwrote refusal")
for (method, args) in [
    ("readBoundSdkState", ["owner": "../synthetic"] as [String: Any]),
    ("exchangeSdkState", ["command": "synthetic_invalid"]),
    ("revokeSdkPrivacy", ["expected": "", "record": "synthetic_invalid"]),
    ("setCrashCapture", ["enabled": true]), ("takePendingCrashes", [:]),
] {
    do { _ = try value(method, args); fatalError("invalid/unscoped native operation accepted") } catch { }
}
if case .unhandled = try channel.call("unknownSyntheticMethod", arguments: [:]) {} else { fatalError("unknown method accepted") }
print("Protected channel: capability, fixed SDK path, owner isolation, expected-raw CAS, ceiling/choice, before-publication disable and fail-closed capture passed")

// Production dispatch must admit refusal while an earlier ordinary read is stuck on state I/O.
let queuedRoot = root.appendingPathComponent("dispatch")
let queuedStore = CorlexFlutterStateStore(directory: queuedRoot)
let dispatcher = CorlexFlutterDispatch()
let queuedChannel = ProtectedStateChannel(state: queuedStore, privacyPath: queuedRoot.appendingPathComponent("privacy.json").path, disableReporter: {})
let queuedGrant = try record("granted")
_ = try queuedStore.exchange(encoded(["owner": owner, "expected": "", "privacy": queuedGrant]))
let queuedGeneration = try object(queuedGrant)["generation"] as! String
try queuedStore.selectScope(owner, queuedGeneration)
let held = DispatchSemaphore(value: 0), release = DispatchSemaphore(value: 0)
let holderDone = DispatchSemaphore(value: 0), readStarted = DispatchSemaphore(value: 0)
let readDone = DispatchSemaphore(value: 0), refusalDone = DispatchSemaphore(value: 0)
DispatchQueue.global().async {
    defer { holderDone.signal() }
    _ = try? queuedStore.withScope(owner, queuedGeneration) { _ in held.signal(); _ = release.wait(timeout: .now() + 5) }
}
check(held.wait(timeout: .now() + 3) == .success)
dispatcher.submit("readBoundSdkState", arguments: ["owner": owner]) {
    readStarted.signal()
    _ = try? queuedChannel.call("readBoundSdkState", arguments: ["owner": owner])
    readDone.signal()
}
check(readStarted.wait(timeout: .now() + 3) == .success)
let queuedDenial = try record("denied")
dispatcher.submit("revokeSdkPrivacy", arguments: ["expected": queuedGrant, "record": queuedDenial]) {
    _ = try? queuedChannel.call("revokeSdkPrivacy", arguments: ["expected": queuedGrant, "record": queuedDenial])
    refusalDone.signal()
}
let until = Date().addingTimeInterval(1)
while Date() < until && CorlexFlutterProcessPrivacy.floor(queuedRoot.standardizedFileURL.path) != queuedDenial { Thread.sleep(forTimeInterval: 0.001) }
let immediateRefusal = CorlexFlutterProcessPrivacy.floor(queuedRoot.standardizedFileURL.path) == queuedDenial
release.signal()
check(holderDone.wait(timeout: .now() + 3) == .success)
check(readDone.wait(timeout: .now() + 3) == .success && refusalDone.wait(timeout: .now() + 3) == .success)
check(immediateRefusal, "queued file read delayed privacy refusal admission")
print("Production dispatch: held SDK file lock cannot delay admitted negative process fence")
