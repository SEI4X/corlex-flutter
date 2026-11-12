package ru.corlex.flutter

import android.util.JsonReader
import android.util.JsonToken
import java.io.StringReader

/** Strict syntax/duplicates/depth before org.json's platform-dependent parser sees cache bytes. */
internal object CrashJson {
    fun validate(text: String) {
        JsonReader(StringReader(text)).use { reader ->
            reader.isLenient = false
            scan(reader, 0, intArrayOf(0))
            require(reader.peek() == JsonToken.END_DOCUMENT)
        }
    }
    private fun scan(reader: JsonReader, depth: Int, nodes: IntArray) {
        require(depth <= 8 && ++nodes[0] <= 65536)
        when (reader.peek()) {
            JsonToken.BEGIN_OBJECT -> {
                reader.beginObject(); val keys = HashSet<String>()
                while (reader.hasNext()) {
                    val key = reader.nextName(); require(key.length <= 256 && keys.add(key))
                    scan(reader, depth + 1, nodes)
                }
                reader.endObject()
            }
            JsonToken.BEGIN_ARRAY -> {
                reader.beginArray()
                while (reader.hasNext()) scan(reader, depth + 1, nodes)
                reader.endArray()
            }
            JsonToken.STRING, JsonToken.NUMBER -> reader.nextString()
            JsonToken.BOOLEAN -> reader.nextBoolean()
            JsonToken.NULL -> reader.nextNull()
            else -> throw IllegalArgumentException("invalid_crash_cache")
        }
    }
}
