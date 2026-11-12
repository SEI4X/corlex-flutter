package ru.corlex.flutter

import java.io.File
import java.nio.file.Files
import java.util.UUID
import org.json.JSONObject
import org.junit.After
import org.junit.Assert.*
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

@RunWith(RobolectricTestRunner::class)
@Config(manifest = Config.NONE, sdk = [24, 35])
class ScopedCrashStoreTest {
    private lateinit var directory: File
    private lateinit var store: CrashStore
    private val binding = CrashBinding("a".repeat(64), UUID.randomUUID().toString())
    @Before fun prepare() { directory = Files.createTempDirectory("corlex-scoped-crash-").toFile(); store = CrashStore(directory, binding) }
    @After fun clean() { directory.deleteRecursively() }
    private fun report(id: String = UUID.randomUUID().toString()) = JSONObject()
        .put("v", 1).put("kind", "native").put("fatal", true).put("source", "java_exception").put("crash_id", id).put("timestamp_ms", 1_761_000_000_000L)
        .put("binding_owner", binding.owner).put("binding_generation", binding.generation)
        .put("name", "java.lang.IllegalStateException").put("message", "synthetic_private")
        .put("app_version", "1.2.3").put("build", "45")
    private fun put(raw: String, id: String): File = File(directory, "crash-$id.json").also { it.writeText(raw) }

    @Test fun replayUsesCurrentMessagePolicyAndKeepsOriginalReleaseAndReceipt() {
        val raw = report().put("private_extra", "synthetic_extra")
        store.write(raw)
        val detailed = JSONObject(store.pending(details = true).single().second)
        assertEquals("synthetic_private", detailed.getString("message"))
        val receipt = store.pending().single(); val safe = JSONObject(receipt.second)
        assertEquals("Unhandled native exception", safe.getString("message")); assertFalse(safe.has("private_extra"))
        assertEquals("1.2.3", safe.getString("app_version")); assertEquals("45", safe.getString("build"))
        assertEquals(1_761_000_000_000L, safe.getLong("timestamp_ms")); assertEquals(raw.getString("crash_id"), receipt.first)
        assertTrue(File(directory, "crash-${receipt.first}.json").exists())
        store.remove(listOf(receipt.first)); assertTrue(store.pending().isEmpty())
    }

    @Test fun foreignScopeAndMalformedDuplicateUtf8OversizeCacheAreDroppedWithoutLosingHealthyReceipt() {
        val valid = report(); store.write(valid)
        fun bad(text: String, bytes: ByteArray? = null) {
            val id = UUID.randomUUID().toString(); val file = put(text, id)
            if (bytes != null) file.writeBytes(bytes)
        }
        val wrong = report().put("binding_owner", "b".repeat(64)); put(wrong.toString(), wrong.getString("crash_id"))
        val old = report().put("binding_generation", UUID.randomUUID().toString()); put(old.toString(), old.getString("crash_id"))
        val duplicate = report(); put(duplicate.toString().dropLast(1) + ",\"binding_owner\":\"${binding.owner}\"}", duplicate.getString("crash_id"))
        bad("{not JSON}"); bad("", byteArrayOf(0xc3.toByte(), 0x28)); bad("", ByteArray(CrashStore.MAX_FILE_BYTES + 1))
        val result = store.pending()
        assertEquals(listOf(valid.getString("crash_id")), result.map { it.first })
        assertEquals(1, directory.listFiles()!!.size)
    }

    @Test fun countLimitIsEnforcedDuringWritingAndInvalidAcknowledgementsNeverEscapeSdkDirectory() {
        repeat(35) { store.write(report()) }
        assertEquals(CrashStore.MAX_FILES, directory.listFiles()!!.count { it.extension == "json" })
        assertEquals(CrashStore.MAX_FILES, store.pending().size)
        val host = File(directory.parentFile, "corlex-host-${UUID.randomUUID()}").also { it.writeText("synthetic_host_data") }
        try {
            store.remove(listOf("../${host.name}", "../../${host.name}", "not_uuid"))
            assertEquals("synthetic_host_data", host.readText())
        } finally { host.delete() }
    }

    @Test fun aCrashSymlinkIsRemovedWithoutReadingOrDeletingTheHostFile() {
        val raw = report(); val id = raw.getString("crash_id")
        val host = File(directory.parentFile, "corlex-host-${UUID.randomUUID()}").also { it.writeText(raw.toString()) }
        val link = File(directory, "crash-$id.json")
        try {
            Files.createSymbolicLink(link.toPath(), host.toPath())
            assertTrue(store.pending().isEmpty()); assertFalse(Files.isSymbolicLink(link.toPath()))
            assertEquals(raw.toString(), host.readText())
        } finally { host.delete() }
    }
}
