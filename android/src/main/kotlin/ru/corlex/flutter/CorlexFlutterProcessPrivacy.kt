// Generated own MIT SDK state helper; see LICENSE and state-protocol-manifest.json.
package ru.corlex.flutter

import java.io.File

/** Refusal does not wait for the SDK file/state mutex, and never trusts an old grant after IO failure. */
internal object CorlexFlutterProcessPrivacy {
  data class Token(val serial: Long, val raw: String)
  sealed class Check { object Admitted : Check(); object Superseded : Check(); data class Stale(val raw: String) : Check() }
  private data class Entry(var physical: String? = null, var floor: String? = null, var serial: Long = 0)
  private val entries = mutableMapOf<String, Entry>()
  @Synchronized private fun <T> entry(key: String, action: (Entry) -> T): T = action(entries.getOrPut(key) { Entry() })
  fun floor(key: String): String? = entry(key) { it.floor }
  fun current(key: String): String? = entry(key) { it.floor ?: it.physical }
  fun read(key: String, raw: String): String = entry(key) {
    if (it.floor != null) return@entry it.floor!!
    if (it.physical != raw) it.serial++
    it.physical = raw
    raw
  }
  fun refuse(key: String, expected: String, raw: String): Token? = entry(key) {
    val known = it.floor ?: it.physical
    if (known != null && known != expected) return@entry null
    if (it.physical == null) it.physical = expected
    it.serial++; it.floor = raw
    Token(it.serial, raw)
  }
  fun confirm(key: String, token: Token, disk: String): Check = entry(key) {
    if (it.serial != token.serial || it.floor != token.raw) return@entry Check.Superseded
    if (it.physical != disk) {
      it.floor = null; it.physical = disk; it.serial++
      return@entry Check.Stale(disk)
    }
    Check.Admitted
  }
  fun wrote(key: String, raw: String) = entry(key) { it.physical = raw }
  fun lease(key: String, expected: String): Long? = entry(key) { if ((it.floor ?: it.physical) == expected) it.serial else null }
  fun valid(key: String, serial: Long): Boolean = entry(key) { it.serial == serial }
  fun granted(key: String, serial: Long, raw: String) = entry(key) {
    it.physical = raw
    if (it.serial == serial) { it.floor = null; it.serial++ }
  }
}
internal class CorlexFlutterScopeOperation<T>(val run: (File) -> T, val invalidated: () -> Unit)
