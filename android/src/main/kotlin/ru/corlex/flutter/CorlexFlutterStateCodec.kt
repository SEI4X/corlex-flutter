// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
package ru.corlex.flutter

import org.json.JSONObject

internal object CorlexFlutterStateCodec {
  const val MAX_BYTES = 8 * 1024 * 1024
  val choices = listOf("granted", "pending", "denied")
  val ownerPattern = Regex("[0-9a-f]{64}")
  val uuid = Regex("[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}")
  val LIMITS = mapOf("corlex_aid" to 4096, "corlex_uid" to 4096,
    "corlex_consent" to 16, "corlex_queue" to 2 * 1024 * 1024,
    "corlex_cfg" to 1024 * 1024 + 1024)
  fun privacy(raw: String): JSONObject {
    require(raw.toByteArray(Charsets.UTF_8).size <= 256) { "privacy_invalid" }
    val row = JSONObject(CorlexFlutterPrivacyJson.parse(raw))
    val keys = row.keys().asSequence().toSet()
    require(row.opt("generation") is String && uuid.matches(row.getString("generation")))
    if (keys == setOf("generation", "state")) row.put("sdkChoice", row.get("state"))
    require(row.keys().asSequence().toSet() == setOf("generation", "state", "sdkChoice"))
    val state = choices.indexOf(row.opt("state")); val choice = choices.indexOf(row.opt("sdkChoice"))
    require(state >= 0 && choice >= 0 && state >= choice) { "privacy_invalid" }
    return row
  }
  fun validate(text: String) {
    require(text.length <= MAX_BYTES && text.toByteArray(Charsets.UTF_8).size <= MAX_BYTES) { "state_budget_exceeded" }
    depthAllowed(text, 1)
    val rows = JSONObject(text)
    for (key in rows.keys()) {
      val max = limit(key) ?: throw IllegalArgumentException("state_invalid")
      val value = rows.get(key)
      require(value is String && value.toByteArray(Charsets.UTF_8).size <= max && (!key.startsWith("m:") || value in choices)) { "state_invalid" }
    }
  }
  fun limit(key: String): Int? {
    LIMITS[key]?.let { return it }
    val marker = key.split(':')
    if (marker.size == 3 && marker[0] == "m" && ownerPattern.matches(marker[1]) && marker[2] == "consent") return 16
    val parts = key.split(':')
    if (parts.size != 4 || parts[0] != "s" || !ownerPattern.matches(parts[1]) || !uuid.matches(parts[2])) return null
    return LIMITS[parts[3]]
  }
  fun depthAllowed(text: String, max: Int) {
    var quoted = false; var escaped = false; var depth = 0
    for (char in text) {
      if (quoted) {
        if (escaped) escaped = false
        else if (char == '\\') escaped = true
        else if (char == '"') quoted = false
      } else when (char) {
        '"' -> quoted = true
        '{' -> { depth++; require(depth <= max) { "state_invalid" } }
        '}' -> { depth--; require(depth >= 0) { "state_invalid" } }
        '[', ']' -> throw IllegalArgumentException("state_invalid")
      }
    }
    require(depth == 0 && !quoted) { "state_invalid" }
  }
}
