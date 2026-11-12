package ru.corlex.flutter

import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicReference
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class CorlexFlutterProcessPrivacyTest {
  private val context = RuntimeEnvironment.getApplication()
  private val owner = "a".repeat(64)
  private val other = "b".repeat(64)
  private fun record(state: String) = JSONObject().put("generation", UUID.randomUUID().toString()).put("state", state).put("sdkChoice", state).toString()
  private fun generation(raw: String) = JSONObject(raw).getString("generation")
  private fun grant(store: CorlexFlutterStateStore, expected: String, next: String, explicit: Boolean = false) {
    val command = JSONObject().put("expected", expected).put("owner", owner).put("privacy", next)
    if (explicit) command.put("explicitChoice", "granted")
    store.exchange(command.toString())
  }
  @Test fun failedSidecarWriteNeverRestoresOldGrantAcrossInstances() {
    val a = CorlexFlutterStateStore(context); val b = CorlexFlutterStateStore(context)
    val initial = record("granted"); val denied = record("denied")
    grant(a, "", initial); a.selectScope(owner, generation(initial))
    val oldDirectory = a.withScope(owner, generation(initial)) { it }
    File(oldDirectory, "old.corlex").writeText("synthetic")
    val directory = File(context.noBackupFilesDir, "corlex-flutter/sdk-state")
    val privacy = File(directory, "privacy.json")
    var stopped = false; var failed = false
    try {
      assertTrue(privacy.setWritable(false, false)); assertTrue(directory.setWritable(false, false))
      try { a.revoke(denied, initial) { stopped = true } } catch (_: Exception) { failed = true }
    } finally { directory.setWritable(true, true); privacy.setWritable(true, true) }
    assertTrue("expected real denied write", failed); assertTrue(stopped)
    assertEquals(denied, b.currentPrivacy())
    val snapshot = JSONObject(b.readBound(owner))
    assertEquals(0, snapshot.getJSONObject("rows").length()); assertFalse(snapshot.has("explicitChoice"))
    try { b.withScope(owner, generation(initial)) { fail("old scope admitted") }; fail("denial bypassed") } catch (_: IllegalArgumentException) { }
    val fresh = record("granted")
    try { grant(b, denied, fresh); fail("default grant lifted denial") } catch (_: IllegalArgumentException) { }
    grant(b, denied, fresh, true)
    assertEquals(fresh, b.currentPrivacy()); assertFalse(oldDirectory.exists())
  }
  @Test fun heldStateLockCannotDelayRefusalOrPermitLateReporterArm() {
    val holding = CorlexFlutterStateStore(context); val withdrawing = CorlexFlutterStateStore(context)
    val initial = record("granted"); val denied = record("denied")
    grant(holding, "", initial); holding.selectScope(owner, generation(initial))
    val entered = CountDownLatch(1); val release = CountDownLatch(1); val floor = CountDownLatch(1)
    val holderDone = CountDownLatch(1); val revokeDone = CountDownLatch(1)
    val rejected = AtomicBoolean(); val invalidated = AtomicBoolean(); val ack = AtomicReference("")
    val previous = Thread.getDefaultUncaughtExceptionHandler()
    val reporter = CrashReporter({ RunFacts("1", "2", "35", "synthetic") })
    try {
      Thread {
        try {
          holding.scoped(owner, generation(initial), CorlexFlutterScopeOperation({ directory ->
            entered.countDown(); release.await(10, TimeUnit.SECONDS)
            reporter.select(CrashActivation(CrashStore(File(directory, "crashes"), CrashBinding(owner, generation(initial))), { it() }))
            reporter.setEnabled(true, false)
            "captured_private"
          }) { invalidated.set(true); reporter.disable() })
        } catch (_: Throwable) { rejected.set(true) }
        finally { holderDone.countDown() }
      }.start()
      assertTrue(entered.await(5, TimeUnit.SECONDS))
      Thread {
        try { ack.set(withdrawing.revoke(denied, initial) { reporter.disable(); floor.countDown() }) }
        catch (_: Throwable) { ack.set("failed") }
        finally { revokeDone.countDown() }
      }.start()
      assertTrue("refusal waited for state lock", floor.await(5, TimeUnit.SECONDS))
      assertEquals(denied, withdrawing.currentPrivacy())
      assertEquals(denied, JSONObject(withdrawing.readBound(owner)).getString("privacy"))
      release.countDown()
      assertTrue(holderDone.await(5, TimeUnit.SECONDS)); assertTrue(revokeDone.await(5, TimeUnit.SECONDS))
      assertTrue(rejected.get()); assertTrue(invalidated.get()); assertEquals(denied, ack.get())
      val enabled = CrashReporter::class.java.getDeclaredField("enabled").apply { isAccessible = true }
      assertFalse("late installation revived capture", enabled.getBoolean(reporter))
    } finally { release.countDown(); reporter.disable(); Thread.setDefaultUncaughtExceptionHandler(previous) }
  }
  @Test fun supersededWithdrawalAcksItselfAndCannotDeleteFreshScope() {
    val old = CorlexFlutterStateStore(context); val newer = CorlexFlutterStateStore(context)
    val initial = record("granted"); val denied = record("denied"); val fresh = record("granted")
    grant(old, "", initial)
    val published = CountDownLatch(1); val resume = CountDownLatch(1); val done = CountDownLatch(1)
    val ack = AtomicReference("")
    Thread {
      try { ack.set(old.revoke(denied, initial) { published.countDown(); resume.await(10, TimeUnit.SECONDS) }) }
      catch (_: Throwable) { ack.set("failed") }
      finally { done.countDown() }
    }.start()
    assertTrue(published.await(5, TimeUnit.SECONDS))
    try {
      grant(newer, denied, fresh, true); newer.selectScope(other, generation(fresh))
      val newFile = newer.withScope(other, generation(fresh)) { File(it, "new.corlex").also { file -> file.writeText("synthetic") } }
      resume.countDown(); assertTrue(done.await(5, TimeUnit.SECONDS))
      assertEquals(denied, ack.get()); assertEquals(fresh, newer.currentPrivacy()); assertTrue(newFile.exists())
      assertEquals(fresh, old.revoke(record("denied"), initial) { fail("stale withdrawal stopped current reporter") })
    } finally { resume.countDown() }
  }
}
