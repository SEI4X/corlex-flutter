package ru.corlex.flutter

import android.content.Context
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.MethodChannel.Result
import java.util.concurrent.Executors

/**
 * The thin native layer of the Corlex Flutter SDK: device facts and the native crash reporter.
 * Everything else (events, queue, Remote Config) is Dart. No ANDROID_ID and no advertising id.
 */
class CorlexFlutterPlugin : FlutterPlugin, MethodCallHandler {
    private lateinit var channel: MethodChannel
    private lateinit var context: Context

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        context = binding.applicationContext
        channel = MethodChannel(binding.binaryMessenger, "ru.corlex/flutter")
        channel.setMethodCallHandler(this)
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel.setMethodCallHandler(null)
    }

    override fun onMethodCall(call: MethodCall, result: Result) {
        when (call.method) {
            "deviceInfo" -> result.success(deviceInfo())
            "trackingStatus" -> result.success(null) // Android has no ATT
            else -> if (call.method in ProtectedStateChannel.methods) {
                val args = (call.arguments as? Map<*, *>)?.toMap() ?: emptyMap<Any?, Any?>()
                val selected = if (call.method in privacyMethods || (call.method == "setCrashCapture" && args["enabled"] != true)) privacyWorker else worker
                selected.execute {
                    val value = try { protectedState.call(call.method, args) }
                    catch (_: Exception) {
                        result.error("corlex_native_unavailable", "Corlex protected SDK operation is unavailable.", null)
                        return@execute
                    }
                    result.success(value)
                }
            } else result.notImplemented()
        }
    }

    private val protectedState by lazy { ProtectedStateChannel(context, nativeCrashes) }

    private val nativeCrashes: NativeCrashAccess get() = shared(context)

    private fun deviceInfo(): Map<String, String?> {
        val run = nativeFacts(context)
        return mapOf(
            "os" to "Android",
            "os_version" to run.osVersion,
            "device_model" to run.deviceModel,
            "support_dir" to context.filesDir.absolutePath,
            "app_version" to run.appVersion,
            "build" to run.build,
        )
    }

    companion object {
        private var shared: NativeCrashAccess? = null
        private var sharedRoot: String? = null
        // Negative helper admission publishes its RAM fence before waiting for file I/O.
        // It must never queue behind an ordinary read which already holds/waits for that lock.
        private val privacyMethods = setOf("revokeSdkPrivacy", "observeSdkCeiling", "exchangeSdkState", "currentSdkPrivacy")
        private val privacyWorker = Executors.newCachedThreadPool { command ->
            Thread(command, "CorlexFlutter.privacy").apply { isDaemon = true }
        }
        private val worker = Executors.newSingleThreadExecutor { command ->
            Thread(command, "CorlexFlutter.state").apply { isDaemon = true }
        }

        /**
         * One store and one reporter per process: a second Flutter engine (add-to-app) must not
         * wrap the uncaught-exception handler a second time.
         */
        @Synchronized
        private fun shared(context: Context): NativeCrashAccess {
            val root = context.noBackupFilesDir.canonicalPath
            if (sharedRoot != root || shared == null) {
                shared?.disable()
                shared = NativeCrashAccess(context)
                sharedRoot = root
            }
            return shared!!
        }
    }
}
