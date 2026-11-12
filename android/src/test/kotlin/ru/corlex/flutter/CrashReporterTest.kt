package ru.corlex.flutter

import org.junit.After
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.json.JSONObject
import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [35])
class CrashReporterTest {
    private lateinit var dir: File
    private lateinit var store: CrashStore
    private val facts = RunFacts("1.2.3", "45", "15", "Pixel 9")
    private var previous: Thread.UncaughtExceptionHandler? = null

    @Before
    fun setUp() {
        dir = Files.createTempDirectory("corlex-crashes").toFile()
        store = CrashStore(dir, CrashBinding("a".repeat(64), UUID.randomUUID().toString()))
        previous = Thread.getDefaultUncaughtExceptionHandler()
    }

    @After
    fun tearDown() {
        Thread.setDefaultUncaughtExceptionHandler(previous)
        dir.deleteRecursively()
    }

    private fun reporter() = CrashReporter({ facts }, { 1_761_000_000_000L }).also {
        it.select(CrashActivation(store, { action -> action() }))
    }

    @Test
    fun `writes the contract report of the run that crashed`() {
        val error = IllegalStateException("boom")
        error.stackTrace = arrayOf(StackTraceElement("ru.corlex.flutter.CrashReporterTest", "contractReport", "CrashReporterTest.kt", 42))
        val report = reporter().report(error, details = true)
        assertEquals("java_exception", report.getString("source"))
        assertEquals("java.lang.IllegalStateException", report.getString("name"))
        assertEquals("boom", report.getString("message"))
        assertEquals(1_761_000_000_000L, report.getLong("timestamp_ms"))
        assertEquals("1.2.3", report.getString("app_version"))
        assertEquals("45", report.getString("build"))
        assertTrue(report.getJSONArray("frames").length() in 1..CrashFrames.MAX_FRAMES)
        val top = report.getJSONArray("frames").getJSONObject(0)
        assertEquals("ru.corlex.flutter.CrashReporterTest.contractReport", top.getString("fn"))
        assertEquals("CrashReporterTest.kt", top.getString("file"))
    }

    @Test
    fun `a cause follows behind a marker frame and keeps a share of the budget`() {
        val root = RuntimeException("root")
        val frames = CrashFrames.of(RuntimeException("outer", root), details = true)
        val markers = (0 until frames.length()).filter { frames.getJSONObject(it).getString("fn").startsWith("Caused by: ") }
        assertEquals(1, markers.size)
        assertTrue(frames.getJSONObject(markers[0]).getString("fn").contains("java.lang.RuntimeException: root"))
        assertEquals(listOf(3, 5, 0), CrashFrames.allocate(listOf(3, 50, 0), 8).toList())
        assertEquals(listOf(10, 90), CrashFrames.allocate(listOf(10, 200), 100).toList())
    }

    @Test
    fun `writes nothing until capture is enabled, and chains to the previous handler`() {
        val seen = mutableListOf<Throwable>()
        Thread.setDefaultUncaughtExceptionHandler { _, e -> seen += e }
        val reporter = reporter()
        reporter.setEnabled(on = true, wipe = false, captureErrorMessages = true) // installs the handler
        val handler = Thread.getDefaultUncaughtExceptionHandler()!!

        reporter.setEnabled(on = false, wipe = false)
        handler.uncaughtException(Thread.currentThread(), RuntimeException("off"))
        assertEquals(0, store.pending().size)

        reporter.setEnabled(on = true, wipe = false, captureErrorMessages = true)
        handler.uncaughtException(Thread.currentThread(), RuntimeException("on"))
        assertEquals(2, seen.size)
        val pending = store.pending(details = true)
        assertEquals(1, pending.size)
        assertEquals("on", JSONObject(pending[0].second).getString("message"))

        store.remove(listOf(pending[0].first))
        assertEquals(0, store.pending().size)
    }

    @Test
    fun `wipe deletes unsent reports and a damaged file is dropped`() {
        val reporter = reporter()
        reporter.record(RuntimeException("ignored while disabled"))
        assertEquals(0, store.pending().size)
        reporter.setEnabled(on = true, wipe = false, captureErrorMessages = true)
        reporter.record(RuntimeException("kept"))
        File(dir, "crash-bad.json").writeText("{not json")
        assertEquals(1, store.pending().size)
        reporter.setEnabled(on = false, wipe = true)
        assertEquals(0, store.pending().size)
        assertNull(dir.listFiles()?.firstOrNull())
    }

    @Test
    fun `message is cut to 512 bytes without splitting a character`() {
        val report = reporter().report(RuntimeException("é".repeat(400)), details = true)
        val message = report.getString("message")
        assertTrue(message.toByteArray().size <= CrashReporter.MAX_MESSAGE)
        assertTrue(message.all { it == 'é' })
    }
}
