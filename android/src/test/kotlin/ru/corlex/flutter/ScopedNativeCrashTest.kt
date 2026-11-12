package ru.corlex.flutter

import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.File
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.RuntimeEnvironment
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class ScopedNativeCrashTest {
    private val context = RuntimeEnvironment.getApplication()
    private val plugin = CorlexFlutterPlugin().also {
        CorlexFlutterPlugin::class.java.getDeclaredField("context").apply { isAccessible = true }.set(it, context)
    }
    private val a = "a".repeat(64)
    private val b = "b".repeat(64)
    private var previous: Thread.UncaughtExceptionHandler? = null
    private var chained = 0
    @Before fun installPrevious() { previous = Thread.getDefaultUncaughtExceptionHandler(); Thread.setDefaultUncaughtExceptionHandler { _, _ -> chained++ } }
    @After fun restorePrevious() { Thread.setDefaultUncaughtExceptionHandler(previous) }
    private class Reply : MethodChannel.Result {
        val done = CountDownLatch(1); var value: Any? = null; var error: String? = null
        override fun success(result: Any?) { value = result; done.countDown() }
        override fun error(code: String, message: String?, details: Any?) { error = code; done.countDown() }
        override fun notImplemented() { error = "missing"; done.countDown() }
    }
    private fun reply(method: String, args: Any? = null) = Reply().also {
        plugin.onMethodCall(MethodCall(method, args), it); assertTrue(it.done.await(5, TimeUnit.SECONDS))
    }
    private fun call(method: String, args: Any? = null) = reply(method, args).also { assertNull(it.error) }.value
    private fun raw(state: String) = JSONObject().put("generation", UUID.randomUUID().toString()).put("state", state).put("sdkChoice", state).toString()
    private fun grant(expected: String = ""): String = raw("granted").also {
        call("exchangeSdkState", mapOf("command" to JSONObject().put("owner", a).put("expected", expected).put("privacy", it).apply { if (expected.isNotEmpty()) put("explicitChoice", "granted") }.toString()))
    }
    private fun args(owner: String, raw: String) = mapOf("owner" to owner, "generation" to JSONObject(raw).getString("generation"))
    private fun enable(owner: String, raw: String, details: Boolean = false) {
        call("selectSdkScope", args(owner, raw))
        call("setCrashCapture", args(owner, raw) + mapOf("enabled" to true, "captureErrorMessages" to details))
    }
    private fun capture(message: String = "synthetic_private") {
        Thread.getDefaultUncaughtExceptionHandler()!!.uncaughtException(Thread.currentThread(), IllegalStateException(message))
    }
    private fun pending(owner: String, raw: String) = call("takePendingCrashes", args(owner, raw)) as List<*>
    private fun report(value: Any?) = JSONObject((value as Map<*, *>)["data"] as String)

    @Test fun actualNativeCaptureIsScopedGenericAcknowledgedAndChainsTheHost() {
        val raw = grant(); enable(a, raw); capture()
        assertEquals(1, chained)
        val info = call("bindingInfo") as Map<*, *>; assertEquals(1, info["crashBinding"])
        val pending = pending(a, raw); assertEquals(1, pending.size)
        val report = report(pending.single())
        assertEquals("Unhandled native exception", report.getString("message")); assertFalse(report.toString().contains("synthetic_private"))
        assertEquals(a, report.getString("binding_owner")); assertEquals(JSONObject(raw).getString("generation"), report.getString("binding_generation"))
        assertTrue(report.get("timestamp_ms") is Number)
        val id = (pending.single() as Map<*, *>)["id"] as String
        assertEquals(id, report.getString("crash_id"))
        assertTrue(CorlexFlutterStateStore.protectedDirectory(context).canonicalPath.startsWith(context.noBackupFilesDir.canonicalPath + File.separator))
        assertFalse(File(context.filesDir, "corlex-flutter/crashes").exists())
        call("ackCrashes", args(a, raw) + mapOf("ids" to listOf(id)))
        assertTrue(pending(a, raw).isEmpty())
    }

    @Test fun foreignAndStaleNativeOperationsCannotReadOrDisableTheCurrentOwner() {
        val raw = grant(); enable(a, raw); capture("synthetic_a")
        val old = report(pending(a, raw).single()).getString("crash_id")
        val handler = Thread.getDefaultUncaughtExceptionHandler()
        enable(b, raw)
        assertTrue(pending(b, raw).isEmpty())
        assertEquals("corlex_native_unavailable", reply("takePendingCrashes", args(a, raw)).error)
        assertEquals("corlex_native_unavailable", reply("setCrashCapture", args(a, raw) + mapOf("enabled" to true)).error)
        assertSame(handler, Thread.getDefaultUncaughtExceptionHandler())
        capture("synthetic_b")
        val next = pending(b, raw); assertEquals(1, next.size)
        assertEquals(b, report(next.single()).getString("binding_owner")); assertNotEquals(old, report(next.single()).getString("crash_id"))
    }

    @Test fun refusalFencesHandlersAndOldAcknowledgementCannotDeleteSameIdInFreshScope() {
        val before = grant(); enable(a, before); capture()
        val saved = pending(a, before).single() as Map<*, *>
        val id = saved["id"] as String
        val denied = raw("denied")
        call("revokeSdkPrivacy", mapOf("expected" to before, "record" to denied))
        capture("synthetic_after_denial"); assertEquals(2, chained)
        val next = grant(denied); enable(a, next)
        val folder = File(CorlexFlutterStateStore.protectedDirectory(context), "crashes").also { it.mkdirs() }
        val newer = report(saved).put("binding_generation", JSONObject(next).getString("generation"))
        val file = File(folder, "crash-$id.json").also { it.writeText(newer.toString()) }
        assertEquals("corlex_native_unavailable", reply("ackCrashes", args(a, before) + mapOf("ids" to listOf(id))).error)
        assertTrue(file.exists()); assertEquals(1, pending(a, next).size)
    }
}
