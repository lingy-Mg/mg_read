package com.mgread.mg_read

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.net.ConnectivityManager
import android.net.NetworkCapabilities
import android.net.Uri
import android.os.Build
import android.provider.Settings
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
 */
class MainActivity : AudioServiceActivity() {
    override fun configureFlutterEngine(flutterEngine: FlutterEngine) {
        super.configureFlutterEngine(flutterEngine)
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

            val apkUri = FileProvider.getUriForFile(this, "$packageName.app_update_provider", apk)
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

    private companion object {
        const val DEVICE_IDENTITY_CHANNEL = "mgread/device_identity"
        const val NETWORK_ENVIRONMENT_CHANNEL = "mgread/network_environment"
        const val APP_UPDATE_CHANNEL = "mgread/app_update"
        const val APK_MIME_TYPE = "application/vnd.android.package-archive"
    }
}

private class AppUpdateException(val code: String) : Exception()
