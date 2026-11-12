// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
import Foundation
import Darwin

/// SDK-only state. It never reads AsyncStorage, accepts a JS path or changes app backup policy.
final class CorlexFlutterStateStore {
  static let shared = CorlexFlutterStateStore()
  private let lock = NSLock()
  private let directory: URL?
  private var selected: (owner: String, generation: String)?
  private var fenceKey: String { directory?.standardizedFileURL.path ?? "" }
  private static let maxBytes = 8 * 1024 * 1024


  init(directory: URL? = nil) {
    self.directory = directory ?? FileManager.default.urls(
      for: .applicationSupportDirectory, in: .userDomainMask
    ).first?.appendingPathComponent("CorlexFlutter/sdk-state", isDirectory: true)
  }

  private func locked<T>(_ body: () throws -> T) throws -> T {
    lock.lock()
    defer { lock.unlock() }
    let path = try prepare().appendingPathComponent(".state.lock").path
    let fd = open(path, O_CREAT | O_RDWR, 0o600)
    guard fd >= 0 else { throw StateError.invalid }
    defer { close(fd) }
    guard flock(fd, LOCK_EX) == 0 else { throw StateError.invalid }
    defer { flock(fd, LOCK_UN) }
    return try body()
  }

  func protectedDirectory() throws -> URL {
    guard CorlexFlutterProcessPrivacy.floor(fenceKey) == nil else { throw StateError.invalid }
    return try locked {
      guard let selected, let privacy = try privacyRecord(), privacy["state"] == "granted",
        privacy["generation"] == selected.generation else { throw StateError.invalid }
      return try scopeDirectory(selected.owner, selected.generation)
    }
  }
  func selectScope(_ owner: String, _ generation: String, beforeChange: () -> Void = {}) throws {
    guard CorlexFlutterProcessPrivacy.floor(fenceKey) == nil else { throw StateError.invalid }
    try locked {
      guard CorlexFlutterStateCodec.ownerValid(owner), UUID(uuidString: generation) != nil,
        let privacy = try privacyRecord(), privacy["state"] == "granted",
        privacy["generation"] == generation else { throw StateError.invalid }
      _ = try scopeDirectory(owner, generation)
      if selected?.owner != owner || selected?.generation != generation { beforeChange() }
      selected = (owner, generation)
    }
  }
  private func scopeDirectory(_ owner: String, _ generation: String) throws -> URL {
    var url = try prepare().appendingPathComponent("scopes/\(owner)/\(generation)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true,
      attributes: [.posixPermissions: 0o700])
    #if os(iOS) || os(tvOS)
    try FileManager.default.setAttributes([.protectionKey: FileProtectionType.completeUntilFirstUserAuthentication], ofItemAtPath: url.path)
    #endif
    var flags = URLResourceValues(); flags.isExcludedFromBackup = true
    try url.setResourceValues(flags)
    return url
  }
  func currentPrivacy() throws -> String {
    if let floor = CorlexFlutterProcessPrivacy.floor(fenceKey) { return floor }
    return try locked { try privacyText() }
  }
  private func privacyText() throws -> String {
    if let floor = CorlexFlutterProcessPrivacy.floor(fenceKey) { return floor }
    return CorlexFlutterProcessPrivacy.read(fenceKey, try privacyDisk())
  }
  private func privacyDisk() throws -> String {
    let file = try prepare().appendingPathComponent("privacy.json")
    if !FileManager.default.fileExists(atPath: file.path) { return "" }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: 257) ?? Data()
    guard data.count <= 256, let raw = String(data: data, encoding: .utf8),
      CorlexFlutterStateCodec.privacy(raw) != nil else { throw StateError.invalid }
    return raw
  }
  private func privacyRecord() throws -> [String: String]? { CorlexFlutterStateCodec.privacy(try privacyText()) }
  func readBound(_ owner: String? = nil) throws -> String {
    if let owner, !CorlexFlutterStateCodec.ownerValid(owner) { throw StateError.invalid }
    if let raw = CorlexFlutterProcessPrivacy.floor(fenceKey), CorlexFlutterStateCodec.privacy(raw)?["sdkChoice"] != "granted" {
      return try CorlexFlutterStateCodec.encoded(["privacy":raw,"rows":[String:String]()] as [String:Any])
    }
    return try locked { try snapshot(owner) }
  }
  private func snapshot(_ owner: String? = nil) throws -> String {
    let raw = try privacyText()
    guard let serial = CorlexFlutterProcessPrivacy.lease(fenceKey, expected: raw) else { throw StateError.invalid }
    if let row = CorlexFlutterStateCodec.privacy(raw), row["sdkChoice"] != "granted" {
      return try CorlexFlutterStateCodec.encoded(["privacy": raw, "rows": [String:String]()] as [String:Any])
    }
    let rows = try JSONSerialization.jsonObject(with: Data(readUnlocked().utf8)) as! [String: String]
    var visible = rows
    if let owner {
      guard CorlexFlutterStateCodec.ownerValid(owner) else { throw StateError.invalid }
      let privacy = CorlexFlutterStateCodec.privacy(raw)
      let prefix = "s:\(owner):\(privacy?["generation"] ?? ""):"
      visible = privacy?["state"] == "granted" ? rows.filter { $0.key.hasPrefix(prefix) } : [:]
    }
    visible = visible.filter { !$0.key.hasPrefix("m:") }
    var result: [String: Any] = ["privacy": raw, "rows": visible]
    if let owner, let choice = rows["m:\(owner):consent"] { result["explicitChoice"] = choice }
    if raw.isEmpty, let choice = rows["corlex_consent"], ["denied", "pending"].contains(choice) {
      result["legacyChoice"] = choice
    }
    let text = String(decoding: try JSONSerialization.data(withJSONObject: result), as: UTF8.self)
    guard CorlexFlutterProcessPrivacy.valid(fenceKey, serial) else { throw StateError.invalid }
    return text
  }
  func exchange(_ command: String, beforePublish: () -> Void = {}) throws -> String {
    let data = Data(command.utf8)
      guard data.count <= Self.maxBytes, CorlexFlutterStateCodec.depthAllowed(data, 2),
        let input = try JSONSerialization.jsonObject(with: data) as? [String: Any],
        let expected = input["expected"] as? String, let owner = input["owner"] as? String,
        CorlexFlutterStateCodec.ownerValid(owner), expected.isEmpty || CorlexFlutterStateCodec.privacy(expected) != nil else { throw StateError.invalid }
    let proposed = input["privacy"] as? String
    if let proposed, CorlexFlutterStateCodec.privacy(proposed) == nil { throw StateError.invalid }
    let negative = proposed.flatMap(CorlexFlutterStateCodec.privacy).flatMap { $0["state"] } != "granted"
    let token = proposed != nil && negative ? CorlexFlutterProcessPrivacy.refuse(fenceKey, expected: expected, raw: proposed!) : nil
    if token != nil { beforePublish() }
    return try locked {
      if let token {
        switch CorlexFlutterProcessPrivacy.confirm(fenceKey, token: token, disk: try privacyDisk()) {
        case .admitted: break
        case .superseded, .stale: return try snapshot(owner)
        }
      }
      guard try token != nil || expected == privacyText() else { return try snapshot(owner) }
      let next = proposed ?? expected
      guard let record = CorlexFlutterStateCodec.privacy(next) else { throw StateError.invalid }
      guard let serial = CorlexFlutterProcessPrivacy.lease(fenceKey, expected: token?.raw ?? expected) else { throw StateError.invalid }
      if record["state"] == "granted", let prior = CorlexFlutterStateCodec.privacy(expected),
        prior["sdkChoice"] != "granted", input["explicitChoice"] as? String != "granted" { throw StateError.invalid }
      var rows = try stateRows()
      if CorlexFlutterProcessPrivacy.floor(fenceKey).flatMap(CorlexFlutterStateCodec.privacy)?["sdkChoice"] != nil &&
        CorlexFlutterProcessPrivacy.floor(fenceKey).flatMap(CorlexFlutterStateCodec.privacy)?["sdkChoice"] != "granted" { rows = [:] }
      let previous = CorlexFlutterStateCodec.privacy(expected)
      let changed = previous?["generation"] != record["generation"] || previous?["state"] != record["state"]
      if changed { rows = rows.filter { $0.key.hasPrefix("m:") } }
      if record["sdkChoice"] != "granted" { rows = [:] }
      rows = try CorlexFlutterStateCodec.mutate(input, record: record, rows: rows)
      let payload = try CorlexFlutterStateCodec.encoded(rows)
      guard payload.utf8.count <= Self.maxBytes, CorlexFlutterStateCodec.valid(Data(payload.utf8))
        else { throw StateError.invalid }
      if next != expected && record["state"] == "granted" {
        beforePublish()
        if changed { try clearScopes() }
        try writeUnlocked(payload)
        guard CorlexFlutterProcessPrivacy.valid(fenceKey, serial) else { return try snapshot(owner) }
        try writeFile(next, "privacy.json")
        CorlexFlutterProcessPrivacy.granted(fenceKey, serial: serial, raw: next)
      } else {
        if next != expected {
          try writeFile(next, "privacy.json"); CorlexFlutterProcessPrivacy.wrote(fenceKey, next)
          if changed { try clearScopes() }
        }
        try writeUnlocked(payload)
      }
      return try snapshot(owner)
    }
  }
  @discardableResult
  func revoke(_ privacy: String, expected: String, beforePublish: () -> Void = {}) throws -> String {
    guard expected.isEmpty || CorlexFlutterStateCodec.privacy(expected) != nil,
      let record = CorlexFlutterStateCodec.privacy(privacy), record["state"] == "denied",
      record["sdkChoice"] == "denied" else { throw StateError.invalid }
    guard let token = CorlexFlutterProcessPrivacy.refuse(fenceKey, expected: expected, raw: privacy)
      else { return CorlexFlutterProcessPrivacy.current(fenceKey) ?? expected }
    beforePublish()
    return try locked {
      switch CorlexFlutterProcessPrivacy.confirm(fenceKey, token: token, disk: try privacyDisk()) {
      case .superseded: return privacy
      case .stale(let actual): return actual
      case .admitted: break
      }
      try writeFile(privacy, "privacy.json"); CorlexFlutterProcessPrivacy.wrote(fenceKey, privacy)
      selected = nil
      try writeUnlocked("{}")
      try clearScopes()
      return privacy
    }
  }
  func observe(_ expected: String, ceiling: String, beforePublish: () -> Void = {}) throws -> String {
    guard var row = CorlexFlutterStateCodec.privacy(expected),
      let ceilingRank = CorlexFlutterStateCodec.choices.firstIndex(of: ceiling),
      let choiceRank = CorlexFlutterStateCodec.choices.firstIndex(of: row["sdkChoice"]!) else { throw StateError.invalid }
    let effective = CorlexFlutterStateCodec.choices[max(ceilingRank, choiceRank)]
    guard effective != row["state"] else { return try currentPrivacy() }
    row["state"] = effective; row["generation"] = UUID().uuidString.lowercased()
    let next = try CorlexFlutterStateCodec.encoded(row)
    let command = try CorlexFlutterStateCodec.encoded(["expected":expected,"owner":String(repeating:"0", count:64),"privacy":next])
    _ = try exchange(command, beforePublish: beforePublish)
    return try currentPrivacy()
  }
  func withScope<T>(_ owner: String, _ generation: String, _ action: @escaping (URL) throws -> T) throws -> T {
    try scoped(owner, generation, CorlexFlutterScopeOperation(run: action, invalidated: {}))
  }
  func scoped<T>(_ owner: String, _ generation: String, _ operation: CorlexFlutterScopeOperation<T>) throws -> T {
    guard CorlexFlutterProcessPrivacy.floor(fenceKey) == nil else { throw StateError.invalid }
    return try locked {
      let raw = try privacyText()
      guard selected?.owner == owner, selected?.generation == generation,
        let record = CorlexFlutterStateCodec.privacy(raw), record["state"] == "granted", record["generation"] == generation,
        let serial = CorlexFlutterProcessPrivacy.lease(fenceKey, expected: raw) else { throw StateError.invalid }
      let directory = try scopeDirectory(owner, generation)
      guard CorlexFlutterProcessPrivacy.valid(fenceKey, serial) else { throw StateError.invalid }
      do {
        let result = try operation.run(directory)
        guard CorlexFlutterProcessPrivacy.valid(fenceKey, serial) else { throw StateError.invalid }
        return result
      } catch { operation.invalidated(); throw error }
    }
  }
  private func stateRows() throws -> [String: String] {
    try JSONSerialization.jsonObject(with: Data(readUnlocked().utf8)) as! [String: String]
  }
  private func clearScopes() throws {
    selected = nil
    let scopes = try prepare().appendingPathComponent("scopes", isDirectory: true)
    if FileManager.default.fileExists(atPath: scopes.path) { try FileManager.default.removeItem(at: scopes) }
  }
  func read() throws -> String { try locked {
    guard try privacyText().isEmpty else { throw StateError.invalid }
    let raw = try privacyText(), serial = CorlexFlutterProcessPrivacy.lease(fenceKey, expected: "")
    let result = try readUnlocked()
    guard raw.isEmpty, let serial, CorlexFlutterProcessPrivacy.valid(fenceKey, serial) else { throw StateError.invalid }
    return result
  } }
  private func readUnlocked() throws -> String {
    let file = try prepare().appendingPathComponent("state.json")
    if !FileManager.default.fileExists(atPath: file.path) { return "{}" }
    let handle = try FileHandle(forReadingFrom: file)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: Self.maxBytes + 1) ?? Data()
    guard data.count <= Self.maxBytes, CorlexFlutterStateCodec.valid(data),
      let text = String(data: data, encoding: .utf8) else { throw StateError.invalid }
    return text
  }
  func write(_ text: String) throws {
    try locked {
      guard try privacyText().isEmpty else { throw StateError.invalid }
      try writeUnlocked(text)
    }
  }
  private func writeUnlocked(_ text: String) throws {
    guard text.utf8.count <= Self.maxBytes, let data = text.data(using: .utf8), CorlexFlutterStateCodec.valid(data)
      else { throw StateError.invalid }
    try writeFile(text, "state.json")
  }
  private func writeFile(_ text: String, _ name: String) throws {
    let data = Data(text.utf8)
    var file = try prepare().appendingPathComponent(name)
    #if os(iOS) || os(tvOS)
      try data.write(to: file, options: [.atomic, .completeFileProtectionUntilFirstUserAuthentication])
    #else
      try data.write(to: file, options: .atomic)
    #endif
    var attributes = URLResourceValues(); attributes.isExcludedFromBackup = true
    try file.setResourceValues(attributes)
    try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: file.path)
  }

  private func prepare() throws -> URL {
    guard var directory else { throw StateError.invalid }
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
    )
    var values = URLResourceValues()
    values.isExcludedFromBackup = true
    try directory.setResourceValues(values)
    return directory
  }

  private enum StateError: Error { case invalid }
}
