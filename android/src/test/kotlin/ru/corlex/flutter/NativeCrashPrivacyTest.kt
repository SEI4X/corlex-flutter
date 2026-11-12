package ru.corlex.flutter

import java.io.File
import java.nio.file.Files
import org.json.JSONObject
import org.junit.Assert.*
import org.junit.Test

class NativeCrashPrivacyTest {
    private class SensitiveError : RuntimeException() {
        var reads = 0
        override val message: String get() { reads++; return "synthetic_private_value" }
    }
    private fun report(error: Throwable, facts: RunFacts = RunFacts("1.0", "12", "15", "Pixel")): JSONObject {
        val directory = Files.createTempDirectory("corlex-private-report-").toFile()
        return try { CrashReporter({ facts }, { 1_761_000_000_000L }).report(error) }
        finally { directory.deleteRecursively() }
    }
    @Test fun defaultCaptureNeverReadsExceptionMessageAndKeepsStaticType() {
        val error = SensitiveError()
        val result = report(error)
        assertEquals(0, error.reads)
        assertEquals("Unhandled native exception", result.getString("message"))
        assertEquals(SensitiveError::class.java.name, result.getString("name"))
        assertEquals(1_761_000_000_000L, result.getLong("timestamp_ms"))
    }
    @Test fun causesAndSourcePathsCannotLeakPrivateTextByDefault() {
        val error = RuntimeException("synthetic_outer", IllegalStateException("synthetic_cause"))
        error.stackTrace = arrayOf(StackTraceElement("com.example.Safe", "run", "/Users/synthetic/private/Account.kt?token=synthetic", 42))
        val result = report(error).toString()
        assertFalse(result.contains("synthetic_outer")); assertFalse(result.contains("synthetic_cause"))
        assertFalse(result.contains("/Users/")); assertFalse(result.contains("token="))
        assertTrue(result.contains("Account.kt")); assertTrue(result.contains("java.lang.IllegalStateException"))
    }
    @Test fun originalReleaseMetadataIsExactOrUnknownInsteadOfPrefixClipping() {
        val oversized = report(RuntimeException(), RunFacts("a".repeat(129), "b".repeat(33), "15", "Pixel"))
        assertEquals("", oversized.getString("app_version")); assertEquals("", oversized.getString("build"))
        val invalid = report(RuntimeException(), RunFacts("x\uD83D", null, "15", "Pixel"))
        assertEquals("", invalid.getString("app_version")); assertEquals("", invalid.getString("build"))
        val exact = report(RuntimeException(), RunFacts("é".repeat(64), "b".repeat(32), "15", "Pixel"))
        assertEquals("é".repeat(64), exact.getString("app_version")); assertEquals("b".repeat(32), exact.getString("build"))
    }
    @Test fun malformedDynamicFrameNamesAreDroppedAndDeepStacksFitWireBudget() {
        val error = RuntimeException("synthetic_private")
        error.stackTrace = arrayOf(StackTraceElement("synthetic@example.test", "run", "Account.kt", 1))
        assertEquals(0, report(error).getJSONArray("frames").length())
        error.stackTrace = (0 until 100).map { StackTraceElement("com.example." + "A".repeat(230), "f$it", "File.kt", it) }.toTypedArray()
        val frames = report(error).getJSONArray("frames")
        assertTrue(frames.toString().toByteArray(Charsets.UTF_8).size <= 16 * 1024)
        assertTrue(frames.length() > 0)
    }
}
