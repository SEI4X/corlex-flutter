// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
package ru.corlex.flutter

import org.json.JSONObject

/** Strict bounded control grammar; JSONObject alone accepts duplicates and non-JSON keys. */
internal object CorlexFlutterPrivacyJson {
  fun parse(text: String): Map<String, String> {
    require(text.toByteArray(Charsets.UTF_8).size <= 256) { "privacy_invalid" }
    return Reader(text).read()
  }
  private class Reader(private val text: String) {
    private var index = 0
    fun read(): Map<String, String> {
      require(take('{')) { "privacy_invalid" }
      val rows = linkedMapOf<String, String>()
      if (!take('}')) while (true) {
        require(rows.size < 3) { "privacy_invalid" }
        val key = string()
        require(!rows.containsKey(key) && take(':')) { "privacy_invalid" }
        rows[key] = string()
        if (take('}')) break
        require(take(',')) { "privacy_invalid" }
      }
      whitespace()
      require(index == text.length) { "privacy_invalid" }
      return rows
    }
    private fun string(): String {
      whitespace()
      val start = index
      require(index < text.length && text[index++] == '"') { "privacy_invalid" }
      while (index < text.length) {
        val char = text[index++]
        if (char == '"') return try {
          JSONObject("{\"v\":" + text.substring(start, index) + "}").getString("v")
        } catch (_: Exception) { throw IllegalArgumentException("privacy_invalid") }
        require(char.code >= 32) { "privacy_invalid" }
        if (char == '\\') {
          require(index < text.length) { "privacy_invalid" }
          val escaped = text[index++]
          if (escaped == 'u') {
            require(index + 4 <= text.length && text.substring(index, index + 4).all { it in '0'..'9' || it in 'a'..'f' || it in 'A'..'F' }) { "privacy_invalid" }
            index += 4
          } else require(escaped in "\"/\\bfnrt") { "privacy_invalid" }
        }
      }
      throw IllegalArgumentException("privacy_invalid")
    }
    private fun whitespace() { while (index < text.length && text[index] in " \r\n\t") index++ }
    private fun take(char: Char): Boolean {
      whitespace()
      if (index >= text.length || text[index] != char) return false
      index++
      return true
    }
  }
}
