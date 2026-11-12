// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
import Foundation

/// A process-local refusal is independent of the filesystem/state mutex and survives failed IO.
enum CorlexFlutterProcessPrivacy {
  struct Token { let serial: UInt64; let raw: String }
  enum Check { case admitted, stale(String), superseded }
  private struct Entry { var physical: String?; var floor: String?; var serial: UInt64 = 0 }
  private static let lock = NSLock()
  private static var entries: [String: Entry] = [:]
  private static func entry<T>(_ key: String, _ body: (inout Entry) -> T) -> T {
    lock.lock(); defer { lock.unlock() }
    var value = entries[key] ?? Entry()
    let result = body(&value); entries[key] = value
    return result
  }
  static func floor(_ key: String) -> String? { entry(key) { $0.floor } }
  static func current(_ key: String) -> String? { entry(key) { $0.floor ?? $0.physical } }
  static func read(_ key: String, _ raw: String) -> String {
    entry(key) {
      if let floor = $0.floor { return floor }
      if $0.physical != raw { $0.serial &+= 1 }
      $0.physical = raw
      return raw
    }
  }
  static func refuse(_ key: String, expected: String, raw: String) -> Token? {
    entry(key) {
      if let known = $0.floor ?? $0.physical, known != expected { return nil }
      $0.physical = $0.physical ?? expected
      $0.serial &+= 1; $0.floor = raw
      return Token(serial: $0.serial, raw: raw)
    }
  }
  static func confirm(_ key: String, token: Token, disk: String) -> Check {
    entry(key) {
      guard $0.serial == token.serial, $0.floor == token.raw else { return .superseded }
      guard $0.physical == disk else {
        $0.floor = nil; $0.physical = disk; $0.serial &+= 1
        return .stale(disk)
      }
      return .admitted
    }
  }
  static func wrote(_ key: String, _ raw: String) { entry(key) { $0.physical = raw } }
  static func serial(_ key: String) -> UInt64 { entry(key) { $0.serial } }
  static func lease(_ key: String, expected: String) -> UInt64? {
    entry(key) { ($0.floor ?? $0.physical) == expected ? $0.serial : nil }
  }
  static func valid(_ key: String, _ serial: UInt64) -> Bool { entry(key) { $0.serial == serial } }
  static func granted(_ key: String, serial: UInt64, raw: String) {
    entry(key) {
      $0.physical = raw
      if $0.serial == serial { $0.floor = nil; $0.serial &+= 1 }
    }
  }
}

struct CorlexFlutterScopeOperation<Value> {
  let run: (URL) throws -> Value
  let invalidated: () -> Void
}
