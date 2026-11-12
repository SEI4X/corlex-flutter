package ru.corlex.flutter

import org.json.JSONObject
import java.util.UUID

/** What the crash file records about the run that crashed (the report keeps these, not the next run's). */
internal data class RunFacts(
    val appVersion: String?,
    val build: String?,
    val osVersion: String,
    val deviceModel: String,
)

/**
 * Uncaught-exception capture: a default handler that writes the report to a file, then calls the
 * handler that was installed before (Crashlytics, Sentry, the Android runtime's own). Nothing is
 * installed, and nothing is written, until consent is granted.
 */
internal class CrashReporter(
    private val facts: () -> RunFacts,
    private val clock: () -> Long = System::currentTimeMillis,
) {
    @Volatile
    private var enabled = false
    private var handler: Handler? = null
    private var activation: CrashActivation? = null

    private class Handler(val previous: Thread.UncaughtExceptionHandler?, val reporter: CrashReporter) :
        Thread.UncaughtExceptionHandler {
        override fun uncaughtException(thread: Thread, error: Throwable) {
            reporter.record(error)
            previous?.uncaughtException(thread, error)
        }
    }

    /** Negative admission never waits for an in-progress report/file write. */
    fun disable() { enabled = false }

    @Synchronized
    fun details(): Boolean = activation?.details ?: false

    @Synchronized
    fun select(next: CrashActivation) { enabled = false; activation = next }

    @Synchronized
    fun setEnabled(on: Boolean, wipe: Boolean, captureErrorMessages: Boolean = false) {
        activation = activation?.copy(details = captureErrorMessages)
        if (on && activation != null && handler == null) {
            val installed = Handler(Thread.getDefaultUncaughtExceptionHandler(), this)
            Thread.setDefaultUncaughtExceptionHandler(installed)
            handler = installed
        }
        enabled = on && activation != null
        if (wipe) activation?.store?.wipe()
    }

    /** Puts the previous handler back, if ours is still the default one. */
    @Synchronized
    fun uninstall() {
        val ours = handler ?: return
        if (Thread.getDefaultUncaughtExceptionHandler() === ours) {
            Thread.setDefaultUncaughtExceptionHandler(ours.previous)
        }
        handler = null
        enabled = false
    }

    /** Writes the report. A failing crash reporter must never replace the crash it was reporting. */
    fun record(error: Throwable) {
        val selected = synchronized(this) { activation?.takeIf { enabled } } ?: return
        try {
            selected.admit {
                synchronized(this) {
                    if (enabled && activation === selected) selected.store.write(report(error, selected.details))
                }
            }
        } catch (_: Throwable) { /* Never replace the host application's original crash. */ }
    }

    fun report(error: Throwable, details: Boolean = false): JSONObject {
        val run = facts()
        return JSONObject()
            .put("v", 1)
            .put("crash_id", UUID.randomUUID().toString())
            .put("timestamp_ms", clock())
            .put("fatal", true)
            .put("source", "java_exception")
            .put("name", CrashPrivacy.name(error.javaClass.name))
            .put("message", CrashPrivacy.message(error, details))
            .put("frames", CrashFrames.of(error, details))
            .put("os_version", CrashPrivacy.metadata(run.osVersion, 128))
            .put("device_model", CrashPrivacy.metadata(run.deviceModel, 128))
            .also { report ->
                report.put("app_version", CrashPrivacy.metadata(run.appVersion, 128))
                report.put("build", CrashPrivacy.metadata(run.build, 32))
            }
    }

    companion object {
        const val MAX_MESSAGE = 512
    }
}
