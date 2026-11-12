package ru.corlex.flutter

import android.content.Context
import android.os.Build

@Suppress("DEPRECATION")
internal fun nativeFacts(context: Context): RunFacts {
    val info = try {
        context.packageManager.getPackageInfo(context.packageName, 0)
    } catch (_: Exception) {
        null
    }
    val build = info?.let {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) it.longVersionCode.toString() else it.versionCode.toString()
    }
    return RunFacts(info?.versionName, build, Build.VERSION.RELEASE ?: "", Build.MODEL ?: "")
}
