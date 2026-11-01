package com.mgread.mg_read

import android.app.ActivityManager
import android.app.Application
import android.app.UiModeManager
import android.content.Context
import android.content.res.Configuration
import android.os.Build
import android.os.Process
import android.util.Log
import io.flutter.FlutterInjector

/**
 * Selects the TV renderer before audio_service can create its cached engine.
 * Manifest metadata resolves resource references when the package is parsed;
 * a values-television boolean therefore cannot select the runtime renderer.
 * Only the main TV process initializes Flutter here. Runtime service processes
 * keep their own startup and non-TV devices retain Flutter's default renderer.
 */
class MgReadApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        val uiMode = getSystemService(Context.UI_MODE_SERVICE) as UiModeManager
        if (uiMode.currentModeType != Configuration.UI_MODE_TYPE_TELEVISION ||
            currentProcessName() != packageName
        ) {
            return
        }
        val loader = FlutterInjector.instance().flutterLoader()
        loader.startInitialization(this)
        loader.ensureInitializationComplete(this, arrayOf("--enable-impeller=false"))
        Log.i("MgReadRendering", "TV renderer initialized: OpenGL (Impeller disabled)")
    }

    private fun currentProcessName(): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return getProcessName()
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
    }
}
