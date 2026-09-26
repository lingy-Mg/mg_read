/**
 * Short-lived private process used for a real app restart after settings save.
 * Only terminates this application's other processes, then launches a fresh
 * main task. A foreground Activity avoids alarm/background-launch permissions.
 */
package com.mgread.mg_read

import android.app.Activity
import android.app.ActivityManager
import android.content.ComponentName
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Process
import android.os.SystemClock
import android.widget.TextView

class AppRestartActivity : Activity() {
    override fun onCreate(savedInstanceState: Bundle?) {
        super.onCreate(savedInstanceState)
        val manager = getSystemService(ACTIVITY_SERVICE) as ActivityManager
        val oldProcesses = manager.runningAppProcesses.orEmpty().filter {
            it.uid == Process.myUid() && it.pid != Process.myPid() &&
                (it.processName == packageName || it.processName.startsWith("$packageName:"))
        }
        oldProcesses.forEach { Process.killProcess(it.pid) }
        // Keep the restart Activity foreground until the old process is gone.
        val handler = Handler(Looper.getMainLooper())
        val deadline = SystemClock.uptimeMillis() + 5000
        fun launchWhenStopped() {
            val remaining = manager.runningAppProcesses.orEmpty().any { running ->
                oldProcesses.any { it.pid == running.pid }
            }
            if (remaining) {
                if (SystemClock.uptimeMillis() >= deadline) {
                    setContentView(TextView(this).apply {
                        text = "重启未完成，请完全关闭 App 后重新打开。"
                        setPadding(32, 64, 32, 32)
                    })
                    return
                }
                handler.postDelayed({ launchWhenStopped() }, 50)
                return
            }
            startActivity(Intent.makeRestartActivityTask(ComponentName(this, MainActivity::class.java)))
            finishAndRemoveTask()
            Process.killProcess(Process.myPid())
        }
        handler.post { launchWhenStopped() }
    }
}
