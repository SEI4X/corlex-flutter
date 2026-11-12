package ru.corlex.flutter

internal data class CrashBinding(val owner: String, val generation: String)
internal data class CrashActivation(
    val store: CrashStore,
    val admit: ((() -> Unit) -> Unit),
    val details: Boolean = false,
)
