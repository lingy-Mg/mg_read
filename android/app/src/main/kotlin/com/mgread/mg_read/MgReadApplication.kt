package com.mgread.mg_read

import android.app.ActivityManager
import android.app.Application
import android.content.Context
import android.os.Build
import android.os.Process

/**
 * Selects the TV renderer before audio_service can create its cached engine.
 * Manifest metadata resolves resource references when the package is parsed;
 * a values-television boolean therefore cannot select the runtime renderer.
 * Only the main application process may initialize Flutter here. Runtime service processes
 * keep their own startup. Renderer launch preferences are owned by
 * MgReadRenderingSettings; automatic retains Flutter defaults on non-TV devices.
 */
class MgReadApplication : Application() {
    override fun onCreate() {
        super.onCreate()
        if (currentProcessName() != packageName) return
        MgReadRenderingSettings.initialize(this)
    }

    private fun currentProcessName(): String? {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) return getProcessName()
        val manager = getSystemService(Context.ACTIVITY_SERVICE) as ActivityManager
        return manager.runningAppProcesses?.firstOrNull { it.pid == Process.myPid() }?.processName
    }
}
