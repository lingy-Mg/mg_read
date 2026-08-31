package com.mgread.mg_read

import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the app-level Android channels that do not belong to a reusable Flutter package.
 * Device manufacturer/model are public build properties and require no runtime permission.
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            DEVICE_IDENTITY_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getDeviceLabel" -> result.success(deviceLabel())
                else -> result.notImplemented()
            }
        }
    }

    private fun deviceLabel(): String {
        val manufacturer = Build.MANUFACTURER.trim()
        val model = Build.MODEL.trim()
        if (manufacturer.isEmpty()) return model
        if (model.isEmpty() || model.startsWith(manufacturer, ignoreCase = true)) {
            return if (model.isEmpty()) manufacturer else model
        }
        return "$manufacturer $model"
    }

    private companion object {
        const val DEVICE_IDENTITY_CHANNEL = "mgread/device_identity"
    }
}
