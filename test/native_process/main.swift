import Foundation

func check(_ value: Bool, _ message: String = "process privacy assertion failed") { precondition(value, message) }
func json(_ value: [String: Any]) throws -> String { try CorlexFlutterStateCodec.encoded(value) }
func record(_ state: String) throws -> String { try json(["generation":UUID().uuidString.lowercased(),"state":state,"sdkChoice":state]) }
func generation(_ raw: String) -> String { CorlexFlutterStateCodec.privacy(raw)!["generation"]! }
let owner = String(repeating:"a", count:64), other = String(repeating:"b", count:64)
let root = FileManager.default.temporaryDirectory.appendingPathComponent("corlex-native-process-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: root) }
final class Box<Value>: @unchecked Sendable {
  private let lock = NSLock(); private var value: Value
  init(_ value: Value) { self.value = value }
  func set(_ next: Value) { lock.lock(); value = next; lock.unlock() }
  func get() -> Value { lock.lock(); defer { lock.unlock() }; return value }
}
func grant(_ store: CorlexFlutterStateStore, _ expected: String, _ next: String, explicit: Bool = false) throws {
  var input: [String:Any] = ["owner":owner,"expected":expected,"privacy":next]
  if explicit { input["explicitChoice"] = "granted" }
  _ = try store.exchange(json(input))
}
// A failed physical sidecar write must never make another same-process instance trust its old grant.
let directory = root.appendingPathComponent("failed-io")
let a = CorlexFlutterStateStore(directory: directory), b = CorlexFlutterStateStore(directory: directory)
let initial = try record("granted"), denied = try record("denied")
try grant(a, "", initial)
try a.selectScope(owner, generation(initial))
let staleDirectory = try a.withScope(owner, generation(initial)) { $0 }
try Data("synthetic".utf8).write(to: staleDirectory.appendingPathComponent("old.corlex"))
try FileManager.default.setAttributes([.posixPermissions:0o500], ofItemAtPath:directory.path)
var disabled = false
 do { try a.revoke(denied, expected: initial) { disabled = true }; fatalError("injected IO failure absent") } catch { }
try FileManager.default.setAttributes([.posixPermissions:0o700], ofItemAtPath:directory.path)
check(disabled)
check(try b.currentPrivacy() == denied, "failed IO restored old grant in another Store")
let refused = try JSONSerialization.jsonObject(with: Data(b.readBound(owner).utf8)) as! [String:Any]
check((refused["rows"] as! [String:String]).isEmpty && refused["explicitChoice"] == nil)
do { _ = try b.withScope(owner, generation(initial)) { _ in "private" }; fatalError("old scope admitted") } catch { }
let fresh = try record("granted")
do { try grant(b, denied, fresh); fatalError("default grant lifted refusal") } catch { }
try grant(b, denied, fresh, explicit: true)
check(try b.currentPrivacy() == fresh)
check(!FileManager.default.fileExists(atPath:staleDirectory.path), "fresh grant replayed old crash scope")

// A held state/file lock cannot delay publishing the refusal or post-action read rejection.
let lockedRoot = root.appendingPathComponent("held-lock")
let holding = CorlexFlutterStateStore(directory:lockedRoot), withdrawing = CorlexFlutterStateStore(directory:lockedRoot)
let heldGrant = try record("granted"), heldDeny = try record("denied")
try grant(holding, "", heldGrant); try holding.selectScope(owner, generation(heldGrant))
let entered = DispatchSemaphore(value:0), release = DispatchSemaphore(value:0), floor = DispatchSemaphore(value:0)
let holderDone = DispatchSemaphore(value:0), revokeDone = DispatchSemaphore(value:0)
let rejected = Box(false), invalidated = Box(false), acknowledged = Box("")
DispatchQueue.global().async {
  do {
    _ = try holding.scoped(owner, generation(heldGrant), CorlexFlutterScopeOperation(run: { _ in
      entered.signal(); _ = release.wait(timeout:.now()+10); return "captured_private"
    }, invalidated: { invalidated.set(true) }))
  } catch { rejected.set(true) }
  holderDone.signal()
}
check(entered.wait(timeout:.now()+5) == .success)
DispatchQueue.global().async {
  do { acknowledged.set(try withdrawing.revoke(heldDeny, expected:heldGrant) { floor.signal() }) }
  catch { acknowledged.set("failed") }
  revokeDone.signal()
}
let floorReady = floor.wait(timeout:.now()+5) == .success
check(floorReady, "refusal waited behind state IO mutex")
check(try withdrawing.currentPrivacy() == heldDeny)
let immediate = try JSONSerialization.jsonObject(with: Data(withdrawing.readBound(owner).utf8)) as! [String:Any]
check(immediate["privacy"] as? String == heldDeny)
release.signal()
check(holderDone.wait(timeout:.now()+5) == .success)
check(revokeDone.wait(timeout:.now()+5) == .success)
check(rejected.get() && invalidated.get(), "post-refusal read/late install escaped admission")
check(acknowledged.get() == heldDeny)

// An admitted old withdrawal may finish after a fresh explicit grant, but cannot erase it or retry it.
let racingRoot = root.appendingPathComponent("choice-order")
let old = CorlexFlutterStateStore(directory:racingRoot), newer = CorlexFlutterStateStore(directory:racingRoot)
let oldGrant = try record("granted"), oldDenial = try record("denied"), newerGrant = try record("granted")
try grant(old, "", oldGrant)
let published = DispatchSemaphore(value:0), resume = DispatchSemaphore(value:0), finished = DispatchSemaphore(value:0)
let oldAck = Box("")
DispatchQueue.global().async {
  do { oldAck.set(try old.revoke(oldDenial, expected:oldGrant) { published.signal(); _ = resume.wait(timeout:.now()+10) }) }
  catch { oldAck.set("failed") }
  finished.signal()
}
check(published.wait(timeout:.now()+5) == .success)
try grant(newer, oldDenial, newerGrant, explicit:true)
try newer.selectScope(other, generation(newerGrant))
let newerDirectory = try newer.withScope(other, generation(newerGrant)) { $0 }
let newerFile = newerDirectory.appendingPathComponent("new.corlex")
try Data("new_synthetic".utf8).write(to:newerFile)
resume.signal(); check(finished.wait(timeout:.now()+5) == .success)
check(oldAck.get() == oldDenial, "old admitted operation returned newer grant as retry metadata")
check(try newer.currentPrivacy() == newerGrant)
check(FileManager.default.fileExists(atPath:newerFile.path), "old refusal cleanup erased newer grant")
let staleAck = try old.revoke(record("denied"), expected:oldGrant) { fatalError("stale withdrawal stopped newer reporter") }
check(staleAck == newerGrant)
print("Process refusal: failed IO, held lock, post-read fence, stale ACK and cleanup-before-explicit-grant passed")
