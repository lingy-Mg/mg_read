package com.mgread.mg_read

import android.content.Context
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.os.Build
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel

/**
 * Hosts the app-level Android channels that do not belong to a reusable Flutter package.
 * Device manufacturer/model and current network capabilities require no runtime permission.
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
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            NETWORK_ENVIRONMENT_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "isWifiConnected" -> result.success(isWifiConnected())
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

    private fun isWifiConnected(): Boolean {
        val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
        return connectivity.allNetworks.any { network ->
            connectivity.getNetworkCapabilities(network)?.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) == true
        }
    }

    private companion object {
        const val DEVICE_IDENTITY_CHANNEL = "mgread/device_identity"
        const val NETWORK_ENVIRONMENT_CHANNEL = "mgread/network_environment"
    }
}
