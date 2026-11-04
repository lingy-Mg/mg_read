package com.mgread.mg_read

import android.app.UiModeManager
import android.content.res.Configuration
import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.media.AudioManager
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
import android.view.KeyEvent
import androidx.core.content.FileProvider
import com.ryanheise.audioservice.AudioServiceActivity
import io.flutter.embedding.engine.FlutterEngine
import io.flutter.plugin.common.MethodChannel
import java.io.File

/**
 * Hosts app-level Android channels that do not belong to reusable Flutter packages.
 *
 * The App-update channel exposes our installed base APK for LAN transfer and hands an
 * already verified received APK to Android's Package Installer. It never attempts a
 * silent install: Android owns the confirmation and the update-signature validation.
 * Device-profile queries also identify the verified MT5893 TV direct-video-surface
 * quirk; presentation mode alone must not change the decoder on other hardware.
 * The rendering-settings channel delegates to native pre-engine launch storage;
 * saving a mode never reconfigures the engine already attached to this Activity.
 */
class MainActivity : AudioServiceActivity() {
    private var localNetworkPermissionResult: MethodChannel.Result? = null

    private fun hasLocalNetworkPermission(): Boolean =
        Build.VERSION.SDK_INT < 37 || applicationInfo.targetSdkVersion < 37 ||
            checkSelfPermission("android.permission.ACCESS_LOCAL_NETWORK") == PackageManager.PERMISSION_GRANTED

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray) {
        super.onRequestPermissionsResult(requestCode, permissions, grantResults)
        if (requestCode == LOCAL_NETWORK_PERMISSION_REQUEST) {
            val pending = localNetworkPermissionResult
            localNetworkPermissionResult = null
            pending?.success(hasLocalNetworkPermission())
        }
    }

    override fun onDestroy() {
        LocalImportBridge.shutdown(this)
        localNetworkPermissionResult?.error("activity_closed", "Activity closed during permission request", null)
        localNetworkPermissionResult = null
        super.onDestroy()
    }
    override fun onNewIntent(intent: Intent) {
        super.onNewIntent(intent)
        LocalImportBridge.forwardNewIntent(intent)
    }

    override fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?) {
        if (!LocalImportBridge.forwardActivityResult(requestCode, resultCode, data)) {
            super.onActivityResult(requestCode, resultCode, data)
        }
    }

    override fun dispatchKeyEvent(event: KeyEvent): Boolean {
        if (com.example.novel_reader_ui.NovelReaderUiPlugin.dispatchVolumeKey(
                event.keyCode,
                event.action,
                event.repeatCount,
            )
        ) {
            return true
        }
        return super.dispatchKeyEvent(event)
    }

    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
        LocalImportBridge.install(this, flutterEngine.dartExecutor.binaryMessenger)
        LocalImportBridge.forwardInitialIntent(intent)
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mgread/rendering_settings")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "get" -> result.success(MgReadRenderingSettings.snapshot(applicationContext))
                    "select" -> {
                        try {
                            result.success(MgReadRenderingSettings.select(applicationContext, call.argument<String>("mode") ?: ""))
                        } catch (error: IllegalArgumentException) {
                            result.error("invalid_rendering_mode", error.message, null)
                        } catch (error: Exception) {
                            result.error("rendering_preference_save_failed", error.javaClass.simpleName, null)
                        }
                    }
                    else -> result.notImplemented()
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mgread/app_lifecycle")
            .setMethodCallHandler { call, result ->
                if (call.method != "restart") {
                    result.notImplemented()
                } else {
                    try {
                        startActivity(Intent(this, AppRestartActivity::class.java)
                            .addFlags(Intent.FLAG_ACTIVITY_NEW_TASK))
                        result.success(null)
                    } catch (error: Exception) {
                        result.error("app_restart_failed", error.javaClass.simpleName, null)
                    }
                }
            }
        MethodChannel(flutterEngine.dartExecutor.binaryMessenger, "mgread/device_profile")
            .setMethodCallHandler { call, result ->
                when (call.method) {
                    "isTelevision" -> result.success(isTelevisionDevice())
                    // MT5893's raw codec-buffer output fails negotiation or
                    // corrupts frames. Its native MediaCodec Surface is usable.
                    "prefersDirectVideoSurface" -> result.success(
                        isTelevisionDevice() && Build.HARDWARE.equals("mt5893", ignoreCase = true)
                    )
                    else -> result.notImplemented()
                }
            }
        if (!flutterEngine.plugins.has(AudioBackgroundPlatformBridge::class.java)) {
            flutterEngine.plugins.add(AudioBackgroundPlatformBridge())
        }
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
                "isLanConnected" -> {
                    val connectivity = getSystemService(Context.CONNECTIVITY_SERVICE) as ConnectivityManager
                    val available = connectivity.allNetworks.any { network ->
                        val capabilities = connectivity.getNetworkCapabilities(network)
                        capabilities != null && !capabilities.hasTransport(NetworkCapabilities.TRANSPORT_VPN) &&
                            (capabilities.hasTransport(NetworkCapabilities.TRANSPORT_WIFI) ||
                                capabilities.hasTransport(NetworkCapabilities.TRANSPORT_ETHERNET))
                    }
                    result.success(available && hasLocalNetworkPermission())
                }
                "requestLocalNetworkPermission" -> {
                    if (hasLocalNetworkPermission()) result.success(true)
                    else if (localNetworkPermissionResult != null) result.error("permission_busy", "Permission request is active", null)
                    else {
                        localNetworkPermissionResult = result
                        requestPermissions(arrayOf("android.permission.ACCESS_LOCAL_NETWORK"), LOCAL_NETWORK_PERMISSION_REQUEST)
                    }
                }
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            APP_UPDATE_CHANNEL,
        ).setMethodCallHandler { call, result ->
            when (call.method) {
                "getInstalledApkPath" -> installedApkPath(result)
                "ensureInstallPermission" -> ensureInstallPermission(result)
                "installApk" -> installApk(call.argument<String>("path"), result)
                else -> result.notImplemented()
            }
        }
        MethodChannel(
            flutterEngine.dartExecutor.binaryMessenger,
            MEDIA_SYSTEM_VOLUME_CHANNEL,
        ).setMethodCallHandler { call, result ->
            val audioManager = getSystemService(Context.AUDIO_SERVICE) as AudioManager
            when (call.method) {
                "isSystemVolumeFixed" -> result.success(audioManager.isVolumeFixed)
                "getSystemVolume" -> {
                    val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val current = audioManager.getStreamVolume(AudioManager.STREAM_MUSIC)
                    result.success(if (maximum == 0) 0.0 else current * 100.0 / maximum)
                }
                "setSystemVolume" -> {
                    val percent = (call.argument<Number>("volume")?.toDouble() ?: 0.0).coerceIn(0.0, 100.0)
                    val maximum = audioManager.getStreamMaxVolume(AudioManager.STREAM_MUSIC)
                    val target = kotlin.math.round(percent * maximum / 100.0).toInt().coerceIn(0, maximum)
                    audioManager.setStreamVolume(AudioManager.STREAM_MUSIC, target, 0)
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        }
    }

    private fun isTelevisionDevice(): Boolean {
        val mode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        return mode.currentModeType == Configuration.UI_MODE_TYPE_TELEVISION ||
            intent?.hasCategory(Intent.CATEGORY_LEANBACK_LAUNCHER) == true ||
            intent?.component?.className?.endsWith("TvLauncher") == true
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

    private fun installedApkPath(result: MethodChannel.Result) {
        val apk = File(applicationInfo.sourceDir)
        if (!apk.isFile || !apk.canRead()) {
            result.error("app_update_package_unavailable", "The installed APK cannot be read.", null)
            return
        }
        result.success(apk.absolutePath)
    }

    private fun ensureInstallPermission(result: MethodChannel.Result) {
        if (Build.VERSION.SDK_INT < Build.VERSION_CODES.O || packageManager.canRequestPackageInstalls()) {
            result.success(null)
            return
        }
        startActivity(
            Intent(
                Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                Uri.parse("package:$packageName"),
            ),
        )
        result.error("app_update_install_permission_required", null, null)
    }

    private fun installApk(path: String?, result: MethodChannel.Result) {
        try {
            if (path.isNullOrBlank()) throw AppUpdateException("app_update_package_invalid")
            val apk = File(path).canonicalFile
            if (!apk.isFile || !apk.canRead() || !apk.name.endsWith(".apk", ignoreCase = true)) {
                throw AppUpdateException("app_update_package_invalid")
            }
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.O && !packageManager.canRequestPackageInstalls()) {
                startActivity(
                    Intent(
                        Settings.ACTION_MANAGE_UNKNOWN_APP_SOURCES,
                        Uri.parse("package:$packageName"),
                    ),
                )
                throw AppUpdateException("app_update_install_permission_required")
            }

            val apkUri = FileProvider.getUriForFile(
                this,
                "$packageName.app_update_provider",
                packageInstallerFile(apk),
            )
            val installer = Intent(Intent.ACTION_VIEW)
                .setDataAndType(apkUri, APK_MIME_TYPE)
                .addFlags(Intent.FLAG_GRANT_READ_URI_PERMISSION)
                // Some older Package Installer implementations only retain the grant from ClipData.
                .apply {
                    clipData = ClipData.newRawUri("mgread-app-update", apkUri)
                }
            startActivity(installer)
            result.success(null)
        } catch (error: AppUpdateException) {
            result.error(error.code, null, null)
        } catch (error: ActivityNotFoundException) {
            result.error("app_update_installer_unavailable", error.javaClass.simpleName, null)
        } catch (error: SecurityException) {
            result.error("app_update_installer_permission_denied", error.javaClass.simpleName, null)
        } catch (error: IllegalArgumentException) {
            result.error("app_update_file_provider_failed", error.javaClass.simpleName, null)
        } catch (error: Exception) {
            // Preserve only the failure class; never expose the local APK path.
            result.error("app_update_installer_failed", error.javaClass.simpleName, null)
        }
    }

    /**
     * FileProvider only exposes files below its configured cache root. The
     * Dart receiver normally downloads there, but stage an older or alternate
     * temporary path here as a final host-side guarantee before installation.
     */
    private fun packageInstallerFile(apk: File): File {
        val directory = File(cacheDir, APP_UPDATE_CACHE_DIRECTORY)
        if (!directory.exists() && !directory.mkdirs()) {
            throw IllegalStateException("Cannot create the App-update cache directory.")
        }
        val cacheRoot = directory.canonicalFile
        if (!cacheRoot.isDirectory) {
            throw IllegalStateException("The App-update cache path is not a directory.")
        }
        val cachePrefix = "${cacheRoot.path}${File.separator}"
        if (apk.path.startsWith(cachePrefix)) return apk

        val staged = File.createTempFile("mgread-update-", ".apk", cacheRoot)
        try {
            apk.copyTo(staged, overwrite = true)
            return staged.canonicalFile
        } catch (error: Exception) {
            staged.delete()
            throw error
        }
    }

    private companion object {
        const val LOCAL_NETWORK_PERMISSION_REQUEST = 47234
        const val DEVICE_IDENTITY_CHANNEL = "mgread/device_identity"
        const val NETWORK_ENVIRONMENT_CHANNEL = "mgread/network_environment"
        const val APP_UPDATE_CHANNEL = "mgread/app_update"
        const val MEDIA_SYSTEM_VOLUME_CHANNEL = "mgread/media_system_volume"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
        const val APP_UPDATE_CACHE_DIRECTORY = "app_updates"
    }
}

private class AppUpdateException(val code: String) : Exception()
