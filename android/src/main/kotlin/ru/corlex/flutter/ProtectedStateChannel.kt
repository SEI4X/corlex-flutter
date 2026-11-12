package ru.corlex.flutter

import android.content.Context
import java.io.File

/** Only SDK-owned state and fixed roots; generated helpers keep the authoritative CAS protocol. */
internal class ProtectedStateChannel(context: Context, private val crashes: NativeCrashAccess) {
    private val state = CorlexFlutterStateStore(context)
    private val privacyPath = File(context.noBackupFilesDir, "corlex-flutter/sdk-state/privacy.json").absolutePath

    fun call(method: String, args: Map<*, *>): Any? = when (method) {
        "bindingInfo" -> {
            state.currentPrivacy()
            mapOf("protectedStorage" to 2, "privacyPath" to privacyPath, "crashBinding" to 1)
        }
        "currentSdkPrivacy" -> state.currentPrivacy()
        "readBoundSdkState" -> state.readBound(text(args, "owner"))
        "exchangeSdkState" -> state.exchange(text(args, "command"), crashes::disable)
        "revokeSdkPrivacy" -> state.revoke(text(args, "record"), text(args, "expected"), crashes::disable)
        "observeSdkCeiling" -> state.observe(text(args, "expected"), text(args, "ceiling"), crashes::disable)
        "selectSdkScope" -> {
            state.selectScope(text(args, "owner"), text(args, "generation"), crashes::disable)
            null
        }
        "setCrashCapture" -> { crashes.enable(binding(args), args); null }
        "takePendingCrashes" -> crashes.pending(binding(args))
        "ackCrashes" -> {
            val ids = args["ids"] as? List<*> ?: throw IllegalArgumentException("invalid_native_request")
            require(ids.size <= CrashStore.MAX_FILES && ids.all { it is String })
            crashes.ack(binding(args), ids.map { it as String }); null
        }
        else -> throw IllegalArgumentException("invalid_native_request")
    }

    private fun binding(args: Map<*, *>) = CrashBinding(text(args, "owner"), text(args, "generation"))

    private fun text(args: Map<*, *>, key: String): String = args[key] as? String
        ?: throw IllegalArgumentException("invalid_native_request")

    companion object {
        val methods = setOf("bindingInfo", "currentSdkPrivacy", "readBoundSdkState", "exchangeSdkState",
            "revokeSdkPrivacy", "observeSdkCeiling", "selectSdkScope", "setCrashCapture", "takePendingCrashes", "ackCrashes")
    }
}
