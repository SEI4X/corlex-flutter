package ru.corlex.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class ProtectedChannelTest {
  private val context = RuntimeEnvironment.getApplication()
  private val plugin = CorlexFlutterPlugin().also {
    CorlexFlutterPlugin::class.java.getDeclaredField("context").apply { isAccessible = true }.set(it, context)
  }
  private val owner = "a".repeat(64)
  private class Reply : MethodChannel.Result {
    val done = CountDownLatch(1)
    var value: Any? = null
    var code: String? = null
    var details: Any? = null
    var missing = false
    override fun success(result: Any?) { value = result; done.countDown() }
    override fun error(errorCode: String, message: String?, errorDetails: Any?) { code = errorCode; details = errorDetails; done.countDown() }
    override fun notImplemented() { missing = true; done.countDown() }
  }
  private fun invoke(method: String, args: Any? = null): Reply = Reply().also {
    plugin.onMethodCall(MethodCall(method, args), it)
    assertTrue("native reply timed out", it.done.await(5, TimeUnit.SECONDS))
  }
  private fun value(method: String, args: Any? = null): Any? = invoke(method, args).also {
    assertFalse("native method missing", it.missing); assertNull("native method rejected", it.code)
  }.value
  private fun privacy(state: String, choice: String = state) = JSONObject().put("generation", UUID.randomUUID().toString())
    .put("state", state).put("sdkChoice", choice).toString()
  private fun exchange(expected: String, next: String) = value("exchangeSdkState", mapOf("command" to JSONObject()
    .put("owner", owner).put("expected", expected).put("privacy", next).toString())) as String

  @Test fun actualEntryAdvertisesProtectedSidecarAndVerifiedScopedCrashCapability() {
    val info = value("bindingInfo") as? Map<*, *> ?: throw AssertionError("bindingInfo shape")
    assertEquals(2, info["protectedStorage"]); assertEquals(1, info["crashBinding"])
    assertEquals(File(context.noBackupFilesDir, "corlex-flutter/sdk-state/privacy.json").canonicalPath, File(info["privacyPath"] as String).canonicalPath)
    assertEquals("", value("currentSdkPrivacy"))
    assertEquals(0, JSONObject(value("readBoundSdkState", mapOf("owner" to owner)) as String).getJSONObject("rows").length())
  }

  @Test fun actualEntryExchangesOwnerStateAndRefusesStalePrivacyPublication() {
    val raw = privacy("granted"); exchange("", raw)
    val generation = JSONObject(raw).getString("generation")
    val command = JSONObject().put("owner", owner).put("expected", raw).put("generation", generation)
      .put("changes", JSONObject().put("corlex_aid", "synthetic_aid"))
    value("exchangeSdkState", mapOf("command" to command.toString()))
    val snapshot = JSONObject(value("readBoundSdkState", mapOf("owner" to owner)) as String)
    assertEquals("synthetic_aid", snapshot.getJSONObject("rows").getString("s:$owner:$generation:corlex_aid"))
    assertEquals(0, JSONObject(value("readBoundSdkState", mapOf("owner" to "b".repeat(64))) as String).getJSONObject("rows").length())
    value("selectSdkScope", mapOf("owner" to owner, "generation" to generation))
    val observed = value("observeSdkCeiling", mapOf("expected" to raw, "ceiling" to "denied")) as String
    assertEquals("denied", JSONObject(observed).getString("state")); assertEquals("granted", JSONObject(observed).getString("sdkChoice"))
    val denied = privacy("denied")
    assertEquals(observed, value("revokeSdkPrivacy", mapOf("expected" to raw, "record" to denied)))
    assertEquals(denied, value("revokeSdkPrivacy", mapOf("expected" to observed, "record" to denied)))
    exchange(raw, privacy("granted")); assertEquals(denied, value("currentSdkPrivacy"))
  }

  @Test fun invalidInputAndLegacyCaptureNeverRevealStateOrErrorDetails() {
    for ((method, args) in listOf(
      "readBoundSdkState" to mapOf("owner" to "../synthetic"),
      "exchangeSdkState" to mapOf("command" to "synthetic_invalid"),
      "revokeSdkPrivacy" to mapOf("expected" to "", "record" to "synthetic_invalid"),
      "setCrashCapture" to mapOf("enabled" to true),
      "takePendingCrashes" to emptyMap<String, String>(),
    )) {
      val reply = invoke(method, args)
      assertFalse(reply.missing); assertEquals("corlex_native_unavailable", reply.code); assertNull(reply.details)
    }
    assertTrue(invoke("unknownSyntheticMethod").missing)
  }
  @Test fun publicEntryReturnsWhileTheSdkFilesystemLockIsHeld() {
    val state = CorlexFlutterStateStore(context)
    val raw = privacy("granted")
    state.exchange(JSONObject().put("owner", owner).put("expected", "").put("privacy", raw).toString())
    val generation = JSONObject(raw).getString("generation")
    state.selectScope(owner, generation)
    val entered = CountDownLatch(1); val release = CountDownLatch(1); val finished = CountDownLatch(1)
    val holder = Thread {
      state.withScope(owner, generation) { entered.countDown(); release.await(5, TimeUnit.SECONDS) }
      finished.countDown()
    }.also { it.start() }
    assertTrue(entered.await(3, TimeUnit.SECONDS))
    val reply = Reply(); val returned = CountDownLatch(1)
    Thread { plugin.onMethodCall(MethodCall("readBoundSdkState", mapOf("owner" to owner)), reply); returned.countDown() }.start()
    val immediate = returned.await(1, TimeUnit.SECONDS)
    release.countDown()
    assertTrue("native entry waited for SDK file I/O", immediate)
    assertTrue(finished.await(3, TimeUnit.SECONDS)); holder.join(3000)
    assertTrue(reply.done.await(5, TimeUnit.SECONDS)); assertNull(reply.code); assertFalse(reply.missing)
  }

  @Test fun queuedFileReadCannotDelayNegativeAdmissionOrHandlerStop() {
    val before = Thread.getDefaultUncaughtExceptionHandler()
    val host = CountDownLatch(1)
    Thread.setDefaultUncaughtExceptionHandler { _, _ -> host.countDown() }
    val grant = privacy("granted"); exchange("", grant)
    val generation = JSONObject(grant).getString("generation")
    value("selectSdkScope", mapOf("owner" to owner, "generation" to generation))
    value("setCrashCapture", mapOf("owner" to owner, "generation" to generation, "enabled" to true))
    val state = CorlexFlutterStateStore(context)
    val held = CountDownLatch(1); val release = CountDownLatch(1)
    val holder = Thread {
      try { state.withScope(owner, generation) { held.countDown(); release.await(5, TimeUnit.SECONDS) } }
      catch (_: IllegalArgumentException) { /* refusal invalidates the admitted operation */ }
    }.also { it.start() }
    assertTrue(held.await(3, TimeUnit.SECONDS))
    val read = Reply(); plugin.onMethodCall(MethodCall("readBoundSdkState", mapOf("owner" to owner)), read)
    val waiting = System.nanoTime() + TimeUnit.SECONDS.toNanos(2)
    while (System.nanoTime() < waiting && Thread.getAllStackTraces().none { (thread, trace) ->
      thread.name == "CorlexFlutter.state" && trace.any { it.methodName == "readBound" }
    }) Thread.yield()
    val denied = privacy("denied"); val refusal = Reply()
    plugin.onMethodCall(MethodCall("revokeSdkPrivacy", mapOf("expected" to grant, "record" to denied)), refusal)
    val key = File(context.noBackupFilesDir, "corlex-flutter/sdk-state").absolutePath
    val deadline = System.nanoTime() + TimeUnit.SECONDS.toNanos(1)
    while (System.nanoTime() < deadline && CorlexFlutterProcessPrivacy.floor(key) != denied) Thread.yield()
    val admitted = CorlexFlutterProcessPrivacy.floor(key) == denied
    val capture = Thread { Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), IllegalStateException("synthetic")) }.also { it.start() }
    val stopped = host.await(1, TimeUnit.SECONDS)
    release.countDown(); holder.join(3000); capture.join(3000)
    Thread.setDefaultUncaughtExceptionHandler(before)
    assertTrue(read.done.await(5, TimeUnit.SECONDS)); assertTrue(refusal.done.await(5, TimeUnit.SECONDS))
    assertTrue("queued file read delayed the privacy floor", admitted)
    assertTrue("queued file read delayed native handler removal", stopped)
    assertEquals(denied, refusal.value); assertNull(refusal.code)
  }

}
