/**
 * Owns the persisted Node host choice. Both hosts remain installed; a write
 * affects the next app process only and does not claim or change the VM gate.
 * Commit before acknowledging so process restart cannot lose the selection.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.os.Build
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodChannel
import java.io.File

internal class AndroidNodeBackendSettings(context: Context, messenger: BinaryMessenger) {
    private val preferences = context.getSharedPreferences("mgread-node-backend", Context.MODE_PRIVATE)
    private val supportsNodeProcess = Build.SUPPORTED_ABIS.contains("arm64-v8a") &&
        File(context.applicationInfo.nativeLibraryDir, "libnode.so").isFile
    private val channel = MethodChannel(messenger, "mgread_plugin_runtime/android_backend")

    init {
        channel.setMethodCallHandler { call, result ->
            when (call.method) {
                "read" -> result.success(mapOf(
                    "selected" to preferences.getString("selected", "javet"),
                    "supportsNodeProcess" to supportsNodeProcess,
                ))
                "select" -> {
                    val backend = call.argument<String>("backend")
                    if (backend != "javet" && backend != "nodeProcess") {
                        result.error("invalid_backend", "Unknown Node backend", null)
                    } else if (backend == "nodeProcess" && !supportsNodeProcess) {
                        result.error("unsupported_backend", "Node process requires arm64 libraries", null)
                    } else if (!preferences.edit().putString("selected", backend).commit()) {
                        result.error("backend_save_failed", "Cannot save Node backend", null)
                    } else {
                        result.success(null)
                    }
                }
                else -> result.notImplemented()
            }
        }
    }

    fun dispose() = channel.setMethodCallHandler(null)
}
