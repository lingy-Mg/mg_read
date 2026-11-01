package com.mgread.mg_read

import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.util.Log
import io.flutter.FlutterInjector

/**
 * Owns device-local renderer launch preferences, needed before Dart can read its
 * database. The selected mode is committed synchronously; the active renderer
 * stays fixed for this process. Runtime service processes do not initialize it.
 * Automatic keeps the TV OpenGL workaround and Flutter defaults on other devices.
 */
object MgReadRenderingSettings {
    private const val PREFERENCES = "mgread_rendering"
    private const val MODE = "mode"
    private val modes = setOf("auto", "opengl", "vulkan")
    private var activeRenderer = "system"

    fun initialize(context: Context) {
        activeRenderer = resolvedRenderer(context, selectedMode(context))
        val arguments = when (activeRenderer) {
            "opengl" -> arrayOf("--enable-impeller=false")
            "vulkan" -> arrayOf("--enable-impeller=true", "--impeller-backend=vulkan")
            else -> emptyArray()
        }
        if (arguments.isNotEmpty()) {
            val loader = FlutterInjector.instance().flutterLoader()
            loader.startInitialization(context)
            loader.ensureInitializationComplete(context, arguments)
        }
        Log.i("MgReadRendering", "Renderer initialized: $activeRenderer selected=${selectedMode(context)}")
    }

    fun snapshot(context: Context): Map<String, Any> {
        val selected = selectedMode(context)
        return mapOf(
            "selected" to selected,
            "activeRenderer" to activeRenderer,
            "restartRequired" to (resolvedRenderer(context, selected) != activeRenderer),
        )
    }

    fun select(context: Context, mode: String): Map<String, Any> {
        require(mode in modes) { "Unsupported rendering mode" }
        check(context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).edit().putString(MODE, mode).commit()) {
            "Could not persist rendering mode"
        }
        return snapshot(context)
    }

    private fun selectedMode(context: Context): String =
        context.getSharedPreferences(PREFERENCES, Context.MODE_PRIVATE).getString(MODE, "auto")
            ?.takeIf { it in modes } ?: "auto"

    private fun resolvedRenderer(context: Context, mode: String): String {
        if (mode != "auto") return mode
        val uiMode = context.getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return if (uiMode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION) "opengl" else "system"
    }
}
