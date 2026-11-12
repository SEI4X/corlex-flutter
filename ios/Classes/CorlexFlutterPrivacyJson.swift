// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
import Foundation

/// Control records contain only a bounded flat object of strings. Decode keys before deduplication.
struct CorlexFlutterPrivacyJson {
  private let bytes: [UInt8]
  private var index = 0
  private enum Invalid: Error { case json }

  static func parse(_ text: String) -> [String: String]? {
    guard text.utf8.count <= 256 else { return nil }
    var reader = CorlexFlutterPrivacyJson(bytes: Array(text.utf8))
    return try? reader.object()
  }
  private mutating func object() throws -> [String: String] {
    guard take(123) else { throw Invalid.json }
    var rows: [String: String] = [:]
    if !take(125) {
      while true {
        guard rows.count < 3 else { throw Invalid.json }
        let key = try string()
        guard rows[key] == nil, take(58) else { throw Invalid.json }
        rows[key] = try string()
        if take(125) { break }
        guard take(44) else { throw Invalid.json }
      }
    }
    whitespace()
    guard index == bytes.count else { throw Invalid.json }
    return rows
  }
  private mutating func string() throws -> String {
    whitespace()
    let start = index
    guard index < bytes.count, bytes[index] == 34 else { throw Invalid.json }
    index += 1
    while index < bytes.count {
      let byte = bytes[index]; index += 1
      if byte == 34 {
        return try JSONDecoder().decode(String.self, from: Data(bytes[start..<index]))
      }
      guard byte >= 32 else { throw Invalid.json }
      if byte == 92 {
        guard index < bytes.count else { throw Invalid.json }
        let escape = bytes[index]; index += 1
        if escape == 117 {
          guard index + 4 <= bytes.count,
            bytes[index..<index + 4].allSatisfy({ (48...57).contains($0) || (65...70).contains($0) || (97...102).contains($0) })
            else { throw Invalid.json }
          index += 4
        } else if ![34, 47, 92, 98, 102, 110, 114, 116].contains(escape) { throw Invalid.json }
      }
    }
    throw Invalid.json
  }
  private mutating func whitespace() {
    while index < bytes.count && [9, 10, 13, 32].contains(bytes[index]) { index += 1 }
  }
  private mutating func take(_ byte: UInt8) -> Bool {
    whitespace()
    guard index < bytes.count, bytes[index] == byte else { return false }
    index += 1
    return true
  }
}
