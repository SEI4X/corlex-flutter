package ru.corlex.flutter

import org.json.JSONArray
import org.json.JSONObject

/**
 * Frames of a Java/Kotlin exception in the shape the mobile contract fixes
 * (services/ingest/docs/protocol.md, "Native SDKs"): `{fn, file, line}` exactly as
 * `Throwable.getStackTrace()` gives them, innermost first, at most [MAX_FRAMES]. The same rules as
 * `packages/sdk-android` (`CrashReport.kt`): a `Caused by` chain follows behind marker frames, and
 * when it does not fit every exception keeps an equal share, so a deep UI stack never pushes the
 * root cause out.
 */
internal object CrashFrames {
    const val MAX_FRAMES = 100
    private const val MAX_CAUSES = 5

    fun of(error: Throwable, details: Boolean = false): JSONArray {
        val chain = chainOf(error)
        val shares = allocate(chain.map { it.stackTrace.size }, MAX_FRAMES - (chain.size - 1))
        val out = JSONArray()
        chain.forEachIndexed { index, throwable ->
            if (index > 0) out.put(JSONObject().put("fn", CrashPrivacy.cause(throwable, details)))
            throwable.stackTrace.take(shares[index]).forEach { CrashPrivacy.frame(it)?.let(out::put) }
        }
        return CrashPrivacy.frames(out, details)
    }

    private fun chainOf(error: Throwable): List<Throwable> {
        val seen = java.util.IdentityHashMap<Throwable, Boolean>()
        val chain = ArrayList<Throwable>()
        var current: Throwable? = error
        while (current != null && chain.size <= MAX_CAUSES && seen.put(current, true) == null) {
            chain.add(current)
            current = current.cause
        }
        return chain
    }

    /** Splits [budget] between stacks of the given [sizes]: equal shares, leftovers to those that need more. */
    fun allocate(sizes: List<Int>, budget: Int): IntArray {
        val shares = IntArray(sizes.size)
        var remaining = budget.coerceAtLeast(0)
        var open = sizes.indices.filter { sizes[it] > 0 }
        while (remaining > 0 && open.isNotEmpty()) {
            val each = maxOf(1, remaining / open.size)
            for (i in open) {
                val give = minOf(each, sizes[i] - shares[i], remaining)
                shares[i] += give
                remaining -= give
            }
            open = open.filter { shares[it] < sizes[it] }
        }
        return shares
    }

    fun messageOf(error: Throwable): String = try {
        error.message ?: ""
    } catch (_: Throwable) {
        ""
    }

    /** Cuts [text] to at most [max] UTF-8 bytes without splitting a character. */
    fun truncateBytes(text: String, max: Int): String {
        if (text.toByteArray(Charsets.UTF_8).size <= max) return text
        var end = minOf(text.length, max) // a character is at least one byte
        while (end > 0 && text.substring(0, end).toByteArray(Charsets.UTF_8).size > max) end--
        if (end > 0 && Character.isHighSurrogate(text[end - 1])) end--
        return text.substring(0, end)
    }
}
