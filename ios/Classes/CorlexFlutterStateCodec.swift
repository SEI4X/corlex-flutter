// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
import Foundation

enum CorlexFlutterStateCodec {
  static let limits = ["corlex_aid": 4096, "corlex_uid": 4096, "corlex_consent": 16,
    "corlex_queue": 2 * 1024 * 1024, "corlex_cfg": 1024 * 1024 + 1024]
  static let choices = ["granted", "pending", "denied"]
  static func privacy(_ raw: String) -> [String: String]? {
    guard raw.utf8.count <= 256, var row = CorlexFlutterPrivacyJson.parse(raw),
      let generation = row["generation"], generation.count == 36, UUID(uuidString: generation) != nil,
      let state = row["state"], let rank = choices.firstIndex(of: state) else { return nil }
    if Set(row.keys) == Set(["generation", "state"]) { row["sdkChoice"] = state }
    guard Set(row.keys) == Set(["generation", "state", "sdkChoice"]),
      let choice = row["sdkChoice"], let choiceRank = choices.firstIndex(of: choice), rank >= choiceRank
      else { return nil }
    return row
  }
  static func encoded(_ object: Any) throws -> String {
    String(decoding: try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self)
  }
  /// Only a flat string dictionary is accepted; depth is checked before Foundation parses JSON.
  static func depthAllowed(_ data: Data, _ maxDepth: Int) -> Bool {
    var quoted = false, escaped = false, depth = 0
    for byte in data {
      if quoted {
        if escaped { escaped = false }
        else if byte == 92 { escaped = true }
        else if byte == 34 { quoted = false }
      } else if byte == 34 { quoted = true }
      else if byte == 123 { depth += 1; if depth > maxDepth { return false } }
      else if byte == 125 { depth -= 1; if depth < 0 { return false } }
      else if byte == 91 || byte == 93 { return false }
    }
    return depth == 0 && !quoted
  }
  static func valid(_ data: Data) -> Bool {
    guard depthAllowed(data, 1),
      let rows = try? JSONSerialization.jsonObject(with: data) as? [String: String]
    else { return false }
    return rows.allSatisfy { key, value in
      guard let limit = limit(key) else { return false }
      return value.utf8.count <= limit && (!key.hasPrefix("m:") || choices.contains(value))
    }
  }
  static func ownerValid(_ owner: String) -> Bool {
    owner.count == 64 && owner.allSatisfy { ("0"..."9").contains($0) || ("a"..."f").contains($0) }
  }
  static func limit(_ key: String) -> Int? {
    if let legacy = limits[key] { return legacy }
    let marker = key.split(separator: ":").map(String.init)
    if marker.count == 3, marker[0] == "m", ownerValid(marker[1]), marker[2] == "consent" { return 16 }
    let parts = key.split(separator: ":", omittingEmptySubsequences: false).map(String.init)
    guard parts.count == 4, parts[0] == "s", ownerValid(parts[1]),
      UUID(uuidString: parts[2]) != nil else { return nil }
    return limits[parts[3]]
  }
  private enum Invalid: Error { case mutation }
  static func mutate(_ input: [String:Any], record: [String:String], rows: [String:String]) throws -> [String:String] {
    var rows = rows
    guard let owner = input["owner"] as? String else { throw Invalid.mutation }
    if let changes = input["changes"] as? [String: Any] {
      guard changes.count <= limits.count, record["state"] == "granted",
        input["generation"] as? String == record["generation"] else { throw Invalid.mutation }
      for (key, value) in changes {
        guard limits[key] != nil else { throw Invalid.mutation }
        let physical = "s:\(owner):\(record["generation"]!):\(key)"
        if value is NSNull { rows.removeValue(forKey: physical) }
        else if let text = value as? String { rows[physical] = text }
        else { throw Invalid.mutation }
        if key == "corlex_consent", let choice = value as? String {
          guard choices.contains(choice) else { throw Invalid.mutation }
          rows["m:\(owner):consent"] = choice
        }
      }
    }
    if let choice = input["explicitChoice"] {
      guard let choice = choice as? String, choices.contains(choice)
        else { throw Invalid.mutation }
      rows["m:\(owner):consent"] = choice
    }
    return rows
  }
}
