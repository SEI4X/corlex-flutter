package ru.corlex.flutter

import android.content.Context
import java.io.File

/** One process handler. All accesses enter StateStore before the reporter, including uncaught writes. */
internal class NativeCrashAccess(context: Context) {
    private val state = CorlexFlutterStateStore(context)
    private val reporter = CrashReporter({ nativeFacts(context) })
    private val root = File(context.noBackupFilesDir.canonicalFile, "corlex-flutter/sdk-state/scopes")

    fun disable() { reporter.disable() }
    fun enable(binding: CrashBinding, args: Map<*, *>) {
        state.scoped(binding.owner, binding.generation, CorlexFlutterScopeOperation(run = { directory ->
            val store = store(directory, binding)
            val activation = CrashActivation(store, { action -> state.scoped(binding.owner, binding.generation, CorlexFlutterScopeOperation(run = { action() }, invalidated = ::disable)) })
            reporter.select(activation)
            reporter.setEnabled(args["enabled"] == true, args["wipe"] == true, args["captureErrorMessages"] == true)
        }, invalidated = ::disable))
    }
    fun pending(binding: CrashBinding): List<Map<String, String>> = state.scoped(binding.owner, binding.generation, CorlexFlutterScopeOperation(run = { directory ->
        // Taking does not acknowledge: a failed HTTP delivery must preserve the original receipt.
        store(directory, binding).pending(details()).map { mapOf("id" to it.first, "data" to it.second) }
    }, invalidated = ::disable))
    fun ack(binding: CrashBinding, ids: List<String>) = state.scoped(binding.owner, binding.generation, CorlexFlutterScopeOperation(run = { directory ->
        store(directory, binding).remove(ids)
    }, invalidated = ::disable))
    private fun store(directory: File, binding: CrashBinding): CrashStore {
        require(directory.canonicalFile == File(root, "${binding.owner}/${binding.generation}").absoluteFile)
        val crashes = File(directory, "crashes")
        require(crashes.canonicalFile == File(directory.canonicalFile, "crashes"))
        return CrashStore(crashes, binding)
    }
    private fun details(): Boolean = reporter.details()
}
