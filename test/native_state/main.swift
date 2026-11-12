import Foundation

func check(_ value: Bool, _ message: String = "native state assertion failed") { precondition(value, message) }

let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-state-\(UUID().uuidString)")
defer { try? FileManager.default.removeItem(at: root) }
let directory = root.appendingPathComponent("state")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
let host = root.appendingPathComponent("host.json")
try Data("synthetic_host_data".utf8).write(to: host)
let state = CorlexFlutterStateStore(directory: directory)
check(try state.read() == "{}")
let values = ["corlex_aid": "a_1", "corlex_queue": "[]"]
func encoded(_ values: [String: String]) throws -> String {
  String(data: try JSONSerialization.data(withJSONObject: values), encoding: .utf8)!
}
try state.write(encoded(values))
let file = directory.appendingPathComponent("state.json")
check(try directory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
check(try file.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
let attrs = try FileManager.default.attributesOfItem(atPath: file.path)
check((attrs[.posixPermissions] as? NSNumber)?.intValue == 0o600)
let reloaded = CorlexFlutterStateStore(directory: directory)
check(try reloaded.read() == encoded(values))
let invalid = ["{\"host_token\":\"synthetic\"}", "{\"corlex_aid\":1}", "{\"corlex_aid\":{}}",
  try encoded(["corlex_queue": String(repeating: "x", count: 2 * 1024 * 1024 + 1)]),
  "{" + String(repeating: "{", count: 10000)]
for text in invalid {
  do { try state.write(text); fatalError("invalid state accepted") } catch { }
  check(try state.read() == encoded(values), "atomic write replaced valid state on rejection")
}
let large = ["corlex_queue": String(repeating: "\"", count: 2 * 1024 * 1024),
  "corlex_cfg": String(repeating: "\"", count: 1024 * 1024 + 1024)]
try state.write(encoded(large))
check(try state.read() == encoded(large), "valid per-key budgets did not survive JSON escaping")
check(try String(contentsOf: host, encoding: .utf8) == "synthetic_host_data")
let all = try FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil)
check(Set(all.map(\.lastPathComponent)) == Set(["state.json", ".state.lock"]))
print("Native state: backup exclusion, permissions, restart, whitelist, byte budgets, atomic rejection and host isolation passed")


func command(_ input: [String: Any]) throws -> String {
  String(decoding: try JSONSerialization.data(withJSONObject: input), as: UTF8.self)
}
func rows(_ snapshot: String) throws -> [String: String] {
  (try JSONSerialization.jsonObject(with: Data(snapshot.utf8)) as! [String: Any])["rows"] as! [String: String]
}
let ownerA = String(repeating: "a", count: 64), ownerB = String(repeating: "b", count: 64)
let generation = UUID().uuidString.lowercased()
let granted = try encoded(["generation": generation, "state": "granted"])
_ = try state.exchange(command(["expected": "", "owner": ownerA, "privacy": granted]))
check(try rows(state.readBound()).isEmpty, "legacy rows were retained across binding migration")
_ = try state.exchange(command(["expected": granted, "owner": ownerA, "generation": generation,
  "changes": ["corlex_aid": "person_a", "corlex_queue": "[]"]]))
_ = try state.exchange(command(["expected": granted, "owner": ownerB, "generation": generation,
  "changes": ["corlex_aid": "person_b"]]))
let saved = try rows(state.readBound())
check(saved["s:\(ownerA):\(generation):corlex_aid"] == "person_a")
check(saved["s:\(ownerB):\(generation):corlex_aid"] == "person_b")
check(try rows(state.readBound(ownerA)).keys.allSatisfy { $0.hasPrefix("s:\(ownerA):") }, "snapshot exposed foreign owner state")
try state.selectScope(ownerA, generation)
let crashDirectory = try state.protectedDirectory()
check(crashDirectory.path.contains("/scopes/\(ownerA)/\(generation)"))
check(try crashDirectory.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
try Data("synthetic_crash".utf8).write(to: crashDirectory.appendingPathComponent("fixture.crash"))
do { try state.write("{}"); fatalError("legacy writer overwrote bound state") } catch { }
check(try rows(state.readBound()) == saved)
let denied = try encoded(["generation": UUID().uuidString.lowercased(), "state": "denied"])
try state.revoke(denied, expected: granted)
check(try state.currentPrivacy() == denied)
check(try rows(state.readBound()).isEmpty)
check(!FileManager.default.fileExists(atPath: crashDirectory.path))
do { _ = try state.protectedDirectory(); fatalError("revoked crash scope remained active") } catch { }
_ = try state.exchange(command(["expected": granted, "owner": ownerA, "generation": generation,
  "changes": ["corlex_aid": "stale_person"]]))
check(try rows(state.readBound()).isEmpty, "stale writer bypassed native CAS")

// The one file budget applies to all owners, and rejection never evicts another live owner.
let nextGeneration = UUID().uuidString.lowercased()
let nextGrant = try encoded(["generation": nextGeneration, "state": "granted"])
_ = try state.exchange(command(["expected": denied, "owner": ownerA, "privacy": nextGrant, "explicitChoice": "granted"]))
for letter in ["a", "b", "c"] {
  _ = try state.exchange(command(["expected": nextGrant, "owner": String(repeating: letter, count: 64),
    "generation": nextGeneration, "changes": ["corlex_queue": String(repeating: "q", count: 2 * 1024 * 1024)]]))
}
let beforeOverflow = try rows(state.readBound())
do {
  _ = try state.exchange(command(["expected": nextGrant, "owner": String(repeating: "d", count: 64),
    "generation": nextGeneration, "changes": ["corlex_queue": String(repeating: "q", count: 2 * 1024 * 1024)]]))
  fatalError("aggregate native state budget was bypassed")
} catch { }
check(try rows(state.readBound()) == beforeOverflow, "budget overflow evicted another owner's state")

// Interruption after publication cannot leave the previous grant authoritative.
try FileManager.default.moveItem(at: file, to: directory.appendingPathComponent("saved-state"))
try FileManager.default.createDirectory(at: file, withIntermediateDirectories: false)
let interruptedDenial = try encoded(["generation": UUID().uuidString.lowercased(), "state": "denied"])
do { try state.revoke(interruptedDenial, expected: nextGrant); fatalError("expected injected state-file failure") } catch { }
check(try state.currentPrivacy() == interruptedDenial, "cleanup failure restored old privacy grant")
check(try String(contentsOf: host, encoding: .utf8) == "synthetic_host_data")
print("Native bound state: namespace separation, stale CAS, global scope wipe, aggregate budget and publish-before-cleanup passed")

// Native choice/ceiling is authoritative even before JS gets another event-loop turn.
let boundRoot = root.appendingPathComponent("choice-state")
let bound = CorlexFlutterStateStore(directory: boundRoot)
func privacy(_ state: String, _ choice: String, _ generation: String = UUID().uuidString.lowercased()) throws -> String {
  try encoded(["state": state, "sdkChoice": choice, "generation": generation])
}
func snapshot(_ owner: String = ownerA) throws -> [String: Any] {
  try JSONSerialization.jsonObject(with: Data(bound.readBound(owner).utf8)) as! [String: Any]
}
let restrictedGrant = try privacy("denied", "granted")
_ = try bound.exchange(command(["expected": "", "owner": ownerA, "privacy": restrictedGrant,
  "explicitChoice": "granted"]))
check(try snapshot()["explicitChoice"] as? String == "granted", "ATT erased explicit SDK choice")
check(try snapshot(ownerB)["explicitChoice"] == nil, "foreign explicit marker exposed")
let restored = try bound.observe(restrictedGrant, ceiling: "granted")
let restoredRecord = CorlexFlutterStateCodec.privacy(restored)!
let restoredGeneration = restoredRecord["generation"]!
check(restoredRecord["state"] == "granted" && restoredRecord["sdkChoice"] == "granted")
check(restored != restrictedGrant, "ATT restoration reused captured generation")
check(try snapshot()["explicitChoice"] as? String == "granted")
try bound.selectScope(ownerA, restoredGeneration)
let selectedDirectory = try bound.withScope(ownerA, restoredGeneration) { $0 }
try Data("synthetic_crash".utf8).write(to: selectedDirectory.appendingPathComponent("fixture.corlex"))
_ = try bound.exchange(command(["expected": restored, "owner": ownerA, "generation": restoredGeneration,
  "changes": ["corlex_aid": "captured_person", "corlex_consent": "granted"]]))
try bound.selectScope(ownerB, restoredGeneration)
do { _ = try bound.withScope(ownerA, restoredGeneration) { _ in false }; fatalError("expected stale owner rejection") } catch { }
var disabled = false
let ceilingDenied = try bound.observe(restored, ceiling: "denied") { disabled = true }
check(disabled && !FileManager.default.fileExists(atPath: selectedDirectory.path))
check(try rows(bound.readBound(ownerA)).isEmpty)
check(try snapshot()["explicitChoice"] as? String == "granted", "observational denial removed retained marker")
let regrant = try bound.observe(ceilingDenied, ceiling: "granted")
let afterStale = try bound.currentPrivacy()
try bound.revoke(privacy("denied", "denied"), expected: restored) { fatalError("stale revoke disabled new generation") }
check(try bound.currentPrivacy() == afterStale)
check(try bound.observe(restored, ceiling: "denied") == afterStale, "stale ATT callback revoked newer generation")
try bound.revoke(privacy("denied", "denied"), expected: regrant)
check(try snapshot()["explicitChoice"] == nil, "SDK withdrawal retained obsolete grant marker")
let deniedChoice = try bound.currentPrivacy()
check(CorlexFlutterStateCodec.privacy(try bound.observe(deniedChoice, ceiling: "granted"))?["state"] == "denied")
let invalidRecords = [
  "{\"generation\":\"\(generation)\",\"state\":\"granted\",\"extra\":\"x\"}",
  "{\"generation\":\"\(generation)\",\"state\":\"granted\",\"sdkChoice\":null}",
  try privacy("granted", "denied"),
]
for record in invalidRecords {
  check(CorlexFlutterStateCodec.privacy(record) == nil, "malformed/restriction-inverting privacy record accepted")
}
let defaultState = CorlexFlutterStateStore(directory: root.appendingPathComponent("default-state"))
_ = try defaultState.exchange(command(["expected": "", "owner": ownerA,
  "privacy": privacy("granted", "granted")]))
let defaultSnapshot = try JSONSerialization.jsonObject(with: Data(defaultState.readBound(ownerA).utf8)) as! [String: Any]
check(defaultSnapshot["explicitChoice"] == nil, "default grant became explicit SDK choice")
print("Native privacy: exact records, ceiling rotation, owner marker isolation, stale CAS and immutable crash scope passed")

let duplicateControls = [
  "{\"generation\":\"\(generation)\",\"state\":\"granted\",\"state\":\"denied\",\"sdkChoice\":\"granted\"}",
  "{\"generation\":\"\(generation)\",\"state\":\"denied\",\"state\":\"granted\",\"sdkChoice\":\"granted\"}",
  "{\"generation\":\"\(generation)\",\"state\":\"granted\",\"\\u0073tate\":\"granted\",\"sdkChoice\":\"granted\"}",
  "{generation:\"\(generation)\",\"state\":\"granted\"}",
  "{\"generation\":\"\(generation)\",\"state\":\"granted\",}",
  "{\"generation\":\"\(generation)\",\"state\":\"granted\"} trailing",
]
for raw in duplicateControls {
  check(CorlexFlutterStateCodec.privacy(raw) == nil, "duplicate/malformed control record accepted")
}
let escapedControl = "{\"generation\":\"\(generation)\",\"\\u0073tate\":\"granted\"}"
check(CorlexFlutterStateCodec.privacy(escapedControl)?["state"] == "granted", "valid escaped JSON key rejected")
print("Strict privacy control JSON: duplicate decoded keys/both orders, malformed grammar and valid escapes passed")
