package ru.corlex.flutter

import java.io.File
import java.util.UUID
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class CorlexFlutterBoundStateTest {
  private val context = RuntimeEnvironment.getApplication()
  private val state = CorlexFlutterStateStore(context)
  private val owner = "a".repeat(64)
  private val other = "b".repeat(64)
  private fun privacy(value: String) = JSONObject().put("generation", UUID.randomUUID().toString()).put("state", value).toString()
  private fun command(expected: String, owner: String = this.owner, changes: JSONObject? = null, next: String? = null): String {
    val input = JSONObject().put("expected", expected).put("owner", owner)
    if (next != null) input.put("privacy", next)
    if (changes != null) input.put("changes", changes).put("generation", JSONObject(expected).getString("generation"))
    return input.toString()
  }
  private fun rows(owner: String? = null) = JSONObject(state.readBound(owner)).getJSONObject("rows")
  @Test fun scopedSnapshotAndRevokeFenceOldWriters() {
    state.write(JSONObject().put("corlex_aid", "legacy_person").put("corlex_queue", "[]").toString())
    val grant = privacy("granted")
    state.exchange(command("", next = grant))
    val generation = JSONObject(grant).getString("generation")
    state.exchange(command(grant, changes = JSONObject().put("corlex_aid", "person_a")))
    state.exchange(command(grant, other, JSONObject().put("corlex_aid", "person_b")))
    assertEquals(2, rows().length())
    assertEquals(1, rows(owner).length())
    assertEquals("person_a", rows(owner).getString("s:$owner:$generation:corlex_aid"))
    state.selectScope(owner, generation)
    val directory = CorlexFlutterStateStore.protectedDirectory(context)
    assertTrue(directory.canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath + File.separator))
    assertTrue(directory.path.endsWith("scopes/$owner/$generation"))
    File(directory, "synthetic.crash").writeText("synthetic only")
    try { state.write("{}"); fail("legacy writer replaced bound state") } catch (_: IllegalArgumentException) { }
    try { state.read(); fail("legacy reader exposed bound state") } catch (_: IllegalArgumentException) { }
    val denied = privacy("denied")
    state.revoke(denied, grant)
    assertEquals(denied, state.currentPrivacy())
    assertFalse(directory.exists())
    state.exchange(command(grant, changes = JSONObject().put("corlex_aid", "stale_person")))
    assertEquals(0, rows().length())
    try { state.selectScope(owner, generation); fail("stale scope was selected") } catch (_: IllegalArgumentException) { }
  }
  @Test fun aggregateBudgetNeverEvictsAnotherLiveOwner() {
    val grant = privacy("granted")
    state.exchange(command("", next = grant))
    for (letter in listOf("a", "b", "c")) {
      state.exchange(command(grant, letter.repeat(64), JSONObject().put("corlex_queue", "q".repeat(2 * 1024 * 1024))))
    }
    val previous = rows().toString()
    try {
      state.exchange(command(grant, "d".repeat(64), JSONObject().put("corlex_queue", "q".repeat(2 * 1024 * 1024))))
      fail("aggregate 8 MiB budget bypassed")
    } catch (_: IllegalArgumentException) { }
    assertEquals(previous, rows().toString())
  }
  @Test fun cleanupFailureCannotRestoreThePreviousGrant() {
    val grant = privacy("granted")
    state.exchange(command("", next = grant))
    val file = File(context.noBackupFilesDir, "corlex-flutter/sdk-state/state.json")
    assertTrue(file.renameTo(File(file.parentFile, "saved-state")))
    assertTrue(file.mkdir())
    File(file, "nonempty").writeText("synthetic")
    // Cover both platform AtomicFile strategies (backup and staged-new file).
    for (suffix in listOf(".bak", ".new")) {
      val obstacle = File(file.path + suffix)
      assertTrue(obstacle.mkdir())
      File(obstacle, "nonempty").writeText("synthetic")
    }
    val denied = privacy("denied")
    try { state.revoke(denied, grant); fail("injected file failure not observed") } catch (_: Exception) { }
    assertEquals(denied, state.currentPrivacy())
  }
  @Test fun explicitChoiceSurvivesEffectiveAttDenial() {
    val restricted = JSONObject(privacy("denied")).put("sdkChoice", "granted").toString()
    state.exchange(JSONObject(command("", next = restricted)).put("explicitChoice", "granted").toString())
    assertEquals("granted", JSONObject(state.readBound(owner)).getString("explicitChoice"))
  }
  @Test fun ceilingRotatesCapturedScopeButRetainsOnlyRequestedOwnerChoice() {
    val grant = JSONObject(privacy("granted")).put("sdkChoice", "granted").toString()
    state.exchange(JSONObject(command("", next = grant)).put("explicitChoice", "granted").toString())
    val generation = JSONObject(grant).getString("generation")
    state.selectScope(owner, generation)
    val scope = state.withScope(owner, generation) { it }
    File(scope, "synthetic.corlex").writeText("synthetic")
    state.selectScope(other, generation)
    try { state.withScope(owner, generation) { fail("stale owner admitted") }; fail("old tuple admitted") } catch (_: IllegalArgumentException) { }
    var disabled = false
    val denied = state.observe(grant, "denied") { disabled = true }
    assertTrue(disabled); assertFalse(scope.exists())
    assertEquals("granted", JSONObject(state.readBound(owner)).getString("explicitChoice"))
    assertFalse(JSONObject(state.readBound(other)).has("explicitChoice"))
    assertEquals(0, rows(owner).length())
    val restored = state.observe(denied, "granted")
    assertNotEquals(generation, JSONObject(restored).getString("generation"))
    state.revoke(privacy("denied"), grant) { fail("stale revoke disabled fresh scope") }
    assertEquals(restored, state.currentPrivacy())
    assertEquals(restored, state.observe(grant, "denied"))
    state.revoke(privacy("denied"), restored)
    assertFalse(JSONObject(state.readBound(owner)).has("explicitChoice"))
    val sdkDenied = state.currentPrivacy()
    assertEquals(sdkDenied, state.observe(sdkDenied, "granted"))
  }
  @Test fun malformedChoiceShapesNeverBecomeLegacyGrant() {
    val invalid = listOf(
      JSONObject(privacy("granted")).put("extra", "ignored"),
      JSONObject(privacy("granted")).put("sdkChoice", JSONObject.NULL),
      JSONObject(privacy("granted")).put("sdkChoice", "denied"))
    for (record in invalid) {
      try { CorlexFlutterStateCodec.privacy(record.toString()); fail("invalid shape accepted") } catch (_: IllegalArgumentException) { }
    }
    val grant = privacy("granted")
    state.exchange(command("", next = grant))
    assertFalse(JSONObject(state.readBound(owner)).has("explicitChoice"))
  }
  @Test fun duplicateDecodedPrivacyKeysAndMalformedGrammarAreRejected() {
    val id = UUID.randomUUID().toString()
    val invalid = listOf(
      "{\"generation\":\"$id\",\"state\":\"granted\",\"state\":\"denied\",\"sdkChoice\":\"granted\"}",
      "{\"generation\":\"$id\",\"state\":\"denied\",\"state\":\"granted\",\"sdkChoice\":\"granted\"}",
      "{\"generation\":\"$id\",\"state\":\"granted\",\"\\u0073tate\":\"granted\",\"sdkChoice\":\"granted\"}",
      "{generation:\"$id\",\"state\":\"granted\"}",
      "{\"generation\":\"$id\",\"state\":granted}",
      "{\"generation\":\"$id\",\"state\":\"granted\",}",
      "{\"generation\":\"$id\",\"state\":\"granted\"} trailing")
    for (raw in invalid) {
      try { CorlexFlutterStateCodec.privacy(raw); fail("duplicate/malformed control accepted") } catch (_: IllegalArgumentException) { }
    }
    assertEquals("granted", CorlexFlutterStateCodec.privacy("{\"generation\":\"$id\",\"\\u0073tate\":\"granted\"}").getString("state"))
  }
}
