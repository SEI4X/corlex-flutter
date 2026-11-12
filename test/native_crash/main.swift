import Foundation
import Darwin

func check(_ value: Bool, _ message: String = "native crash assertion failed") { precondition(value, message) }
let mode = CommandLine.arguments[1]
let root = URL(fileURLWithPath: CommandLine.arguments[2], isDirectory: true).resolvingSymlinksInPath()
let state = CorlexFlutterStateStore(directory: root)
let channel = ProtectedStateChannel(state: state, privacyPath: root.appendingPathComponent("privacy.json").path) {}
let owner = String(repeating: "a", count: 64), other = String(repeating: "b", count: 64)
let generation = UUID().uuidString.lowercased()
func encode(_ object: Any) throws -> String { String(decoding: try JSONSerialization.data(withJSONObject: object), as: UTF8.self) }
func value(_ method: String, _ args: [String: Any] = [:]) throws -> Any? {
    switch try channel.call(method, arguments: args) {
    case .value(let value): return value
    case .unhandled: fatalError("missing native crash route")
    }
}
func rejects(_ action: () throws -> Void) { do { try action(); fatalError("stale/invalid crash operation accepted") } catch {} }
func scope(_ owner: String, _ generation: String) -> [String: Any] { ["owner": owner, "generation": generation] }
let grant = try encode(["generation": generation, "state": "granted", "sdkChoice": "granted"])
_ = try value("exchangeSdkState", ["command": encode(["owner": owner, "expected": "", "privacy": grant])])
_ = try value("selectSdkScope", scope(owner, generation))
var args = scope(owner, generation); args["enabled"] = true
args["captureErrorMessages"] = mode == "details"
_ = try value("setCrashCapture", args)
let directory = root.appendingPathComponent("scopes/\(owner)/\(generation)/crashes", isDirectory: true)
func pending(_ args: [String: Any]) throws -> [[String: String]] { try value("takePendingCrashes", args) as! [[String: String]] }
let exception = NSException(name: NSExceptionName("synthetic_contact@example.test"), reason: "synthetic_private_detail", userInfo: nil)
if mode == "stale-disable" {
    _ = try value("selectSdkScope", scope(other, generation))
    var enabledB = scope(other, generation); enabledB["enabled"] = true
    _ = try value("setCrashCapture", enabledB)
    var staleOff = scope(owner, generation); staleOff["enabled"] = false
    rejects { _ = try value("setCrashCapture", staleOff) }
    NSGetUncaughtExceptionHandler()?(exception)
    check(try pending(scope(other, generation)).count == 1, "stale A disable stopped B capture")
    var admittedOff = scope(other, generation); admittedOff["enabled"] = false
    _ = try value("setCrashCapture", admittedOff)
    print("Scoped disable: stale A rejected, actual B exception retained, current B disable admitted")
    exit(0)
}
if mode == "blocked" {
    let fd = open(root.appendingPathComponent(".state.lock").path, O_RDWR)
    check(fd >= 0 && flock(fd, LOCK_EX) == 0)
    let writerDone = DispatchSemaphore(value: 0), refusalStarted = DispatchSemaphore(value: 0), refusalDone = DispatchSemaphore(value: 0)
    let denial = try encode(["generation": UUID().uuidString.lowercased(), "state": "denied", "sdkChoice": "denied"])
    DispatchQueue.global().async { NSGetUncaughtExceptionHandler()?(exception); writerDone.signal() }
    DispatchQueue.global().async {
        _ = try? state.revoke(denial, expected: grant) { CorlexCrashCapture.shared.setEnabled(false, wipe: false); refusalStarted.signal() }
        refusalDone.signal()
    }
    check(refusalStarted.wait(timeout: .now() + 2) == .success, "refusal waited on filesystem lock")
    check(try state.currentPrivacy() == denial, "RAM refusal lost while disk locked")
    check(corlex_crash_open_report() == -1, "C writer admitted after refusal")
    flock(fd, LOCK_UN); close(fd)
    check(writerDone.wait(timeout: .now() + 3) == .success)
    check(refusalDone.wait(timeout: .now() + 3) == .success)
    check(!FileManager.default.fileExists(atPath: directory.path), "refused writer recreated old scope")
    print("Blocked filesystem: immediate C disable, RAM floor and stale exception rejection passed")
    exit(0)
}
NSGetUncaughtExceptionHandler()?(exception)
let reports = try pending(scope(owner, generation))
check(reports.count == 1, "physical C/Swift exception report missing")
let text = reports[0]["data"]!
check(!text.contains("synthetic_contact@example.test"), "dynamic exception name persisted")
check(text.contains(mode == "details" ? "synthetic_private_detail" : "Error details omitted"))
if mode != "details" { check(!text.contains("synthetic_private_detail"), "default message persisted") }
let header = try JSONSerialization.jsonObject(with: Data(text.split(separator: "\n")[0].utf8)) as! [String: Any]
check(header["binding_owner"] as? String == owner && header["binding_generation"] as? String == generation)
let expectedVersion = mode == "boundary" ? String(repeating: "v", count: 128) : mode == "oversize" ? "" : "0.1.0"
let expectedBuild = mode == "boundary" ? String(repeating: "b", count: 32) : mode == "oversize" ? "" : "1"
check(header["app_version"] as? String == expectedVersion && header["build"] as? String == expectedBuild)
check(header["timestamp_ms"] is NSNumber && header["name"] as? String == "NativeError")
check(try pending(scope(owner, generation)).count == 1, "taking acknowledged before Dart durable enqueue")
let flags = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
check(flags.isExcludedFromBackup == true)
let attrs = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent("crash-\(reports[0]["id"]!).corlex").path)
check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
_ = try value("selectSdkScope", scope(other, generation))
check(try pending(scope(other, generation)).isEmpty, "project B recovered project A crash")
rejects { _ = try pending(scope(owner, generation)) }
rejects { _ = try value("ackCrashes", scope(owner, generation).merging(["ids": [reports[0]["id"]!]]) { _, new in new }) }
_ = try value("selectSdkScope", scope(owner, generation))
// A replay placed in the right directory still needs the immutable header tuple.
let foreignId = UUID().uuidString.lowercased()
let foreign = directory.appendingPathComponent("crash-\(foreignId).corlex")
try (encode(["crash_id": foreignId, "binding_owner": other, "binding_generation": generation]) + "\n").write(to: foreign, atomically: true, encoding: .utf8)
let large = directory.appendingPathComponent("crash-\(UUID().uuidString.lowercased()).corlex")
try Data(repeating: 120, count: 256 * 1024 + 1).write(to: large)
let link = directory.appendingPathComponent("crash-\(UUID().uuidString.lowercased()).corlex")
try FileManager.default.createSymbolicLink(at: link, withDestinationURL: foreign)
check(try pending(scope(owner, generation)).count == 1, "foreign, symlink or oversized report returned")
rejects { _ = try value("ackCrashes", scope(owner, generation).merging(["ids": ["../../synthetic"]]) { _, new in new }) }
_ = try value("ackCrashes", scope(owner, generation).merging(["ids": [reports[0]["id"]!]]) { _, new in new })
check(try pending(scope(owner, generation)).isEmpty)
let denial = try encode(["generation": UUID().uuidString.lowercased(), "state": "denied", "sdkChoice": "denied"])
_ = try value("revokeSdkPrivacy", ["record": denial, "expected": grant])
rejects { _ = try value("setCrashCapture", args) }
check(corlex_crash_open_report() == -1)
check(!FileManager.default.fileExists(atPath: directory.path))
print("Scoped physical writer: \(mode), owner isolation, retained receipt/ack, bounded no-follow reads, withdrawal passed")
