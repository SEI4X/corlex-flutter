package ru.corlex.flutter

import android.util.AtomicFile
import java.io.File
import java.nio.ByteBuffer
import java.nio.charset.CodingErrorAction
import org.json.JSONObject

/** The access owner holds the state lock. Receipts never escape the immutable scope tuple. */
internal class CrashStore(private val directory: File, val binding: CrashBinding) {
    fun write(report: JSONObject) {
        require(directory.isDirectory || directory.mkdirs())
        val id = report.getString("crash_id"); require(ID.matches(id))
        report.put("kind", "native").put("binding_owner", binding.owner).put("binding_generation", binding.generation)
        val bytes = report.toString().toByteArray(Charsets.UTF_8); require(bytes.size <= MAX_FILE_BYTES)
        val target = File(directory, "crash-$id.json")
        require(listOf(target, File(target.path + ".new"), File(target.path + ".bak")).all(::owned))
        val atomic = AtomicFile(target)
        val output = atomic.startWrite()
        try {
            output.write(bytes); output.fd.sync(); atomic.finishWrite(output)
        } catch (failure: Throwable) { atomic.failWrite(output); throw failure }
        require(target.setReadable(false, false) && target.setWritable(false, false))
        require(target.setReadable(true, true) && target.setWritable(true, true))
        files().dropLast(MAX_FILES).forEach { it.delete() }
    }

    fun pending(details: Boolean = false): List<Pair<String, String>> {
        val candidates = files()
        candidates.dropLast(MAX_FILES).forEach { it.delete() }
        return candidates.takeLast(MAX_FILES).mapNotNull { file ->
            try {
                require(owned(file) && file.length() <= MAX_FILE_BYTES)
                val bytes = readBounded(file)
                require(bytes.size <= MAX_FILE_BYTES)
                val text = Charsets.UTF_8.newDecoder().onMalformedInput(CodingErrorAction.REPORT)
                    .onUnmappableCharacter(CodingErrorAction.REPORT).decode(ByteBuffer.wrap(bytes)).toString()
                CrashJson.validate(text)
                val raw = JSONObject(text); val id = file.name.removePrefix("crash-").removeSuffix(".json")
                require(ID.matches(id) && raw.opt("crash_id") == id && raw.opt("v") == 1)
                require(raw.opt("fatal") == true && raw.opt("source") == "java_exception" && raw.opt("kind") == "native")
                require(raw.opt("binding_owner") == binding.owner && raw.opt("binding_generation") == binding.generation)
                val timestamp = raw.opt("timestamp_ms") as? Number ?: error("invalid_crash")
                val time = timestamp.toDouble(); require(time.isFinite() && time >= 0 && time <= 8.64e15 && time % 1 == 0.0)
                val clean = sanitized(raw, details).put("crash_id", id).put("timestamp_ms", timestamp)
                id to clean.toString()
            } catch (_: Exception) { file.delete(); null }
        }
    }

    fun remove(ids: List<String>) {
        for (id in ids.take(MAX_FILES)) if (ID.matches(id)) File(directory, "crash-$id.json").delete()
    }
    fun wipe() { directory.listFiles()?.forEach { if (!it.isDirectory || !owned(it)) it.delete() } }

    private fun sanitized(raw: JSONObject, details: Boolean): JSONObject = JSONObject()
        .put("v", 1).put("kind", "native").put("fatal", true).put("source", "java_exception")
        .put("binding_owner", binding.owner).put("binding_generation", binding.generation)
        .put("name", CrashPrivacy.name(raw.opt("name"))).put("message", CrashPrivacy.storedMessage(raw.opt("message"), details))
        .put("frames", CrashPrivacy.frames(raw.optJSONArray("frames"), details))
        .put("app_version", CrashPrivacy.metadata(raw.opt("app_version"), 128)).put("build", CrashPrivacy.metadata(raw.opt("build"), 32))
        .put("os_version", CrashPrivacy.metadata(raw.opt("os_version"), 128)).put("device_model", CrashPrivacy.metadata(raw.opt("device_model"), 128))

    private fun readBounded(file: File): ByteArray = file.inputStream().use { input ->
        val bytes = ByteArray(MAX_FILE_BYTES + 1); var count = 0
        while (count < bytes.size) {
            val next = input.read(bytes, count, bytes.size - count)
            if (next < 0) break
            count += next
        }
        require(count <= MAX_FILE_BYTES)
        bytes.copyOf(count)
    }
    private fun owned(file: File): Boolean = try {
        file.canonicalFile.parentFile == directory.canonicalFile && file.canonicalFile.name == file.name
    } catch (_: Exception) { false }
    private fun files(): List<File> = (directory.listFiles { f -> f.name.startsWith("crash-") && f.name.endsWith(".json") } ?: emptyArray())
        .sortedWith(compareBy({ it.lastModified() }, { it.name }))

    companion object {
        const val MAX_FILES = 20
        const val MAX_FILE_BYTES = 256 * 1024
        private val ID = Regex("[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}")
    }
}
