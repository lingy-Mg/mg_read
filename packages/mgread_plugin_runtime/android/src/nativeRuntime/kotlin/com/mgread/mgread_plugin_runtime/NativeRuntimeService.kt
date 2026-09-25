/**
 * Owns the Rust Runtime host in an app-private Android process.
 *
 * Binder requests stay small. Native startup runs on a HandlerThread, while
 * HTTP and source work are served directly by Rust on loopback. Stop kills
 * only this service's private process so the host listener cannot outlive it.
 */
package com.mgread.mgread_plugin_runtime

import android.app.ActivityManager
import android.app.Application
import android.app.Service
import android.content.Context
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.HandlerThread
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.Process
import android.util.Log
import java.util.concurrent.Executors

internal object NativeRuntimeMessages {
    const val START = 1
    const val STOP = 2
    const val READY = 3
    const val STOPPED = 4
    const val ERROR = 5
    const val TOKEN = "token"
    const val ROOT = "root"
    const val READY_JSON = "readyJson"
    const val ERROR_CODE = "errorCode"
    const val ERROR_MESSAGE = "errorMessage"
}

class NativeRuntimeService : Service() {
    private lateinit var workerThread: HandlerThread
    private lateinit var serviceMessenger: Messenger
    private lateinit var workerHandler: Handler
    private val startupExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "MgReadNativeStartup").apply { isDaemon = true }
    }
    private val mainHandler = Handler(Looper.getMainLooper())
    @Volatile private var startedToken: String? = null
    private var readyJson: String? = null
    @Volatile private var stopRequested = false

    override fun onCreate() {
        super.onCreate()
        workerThread = HandlerThread("MgReadNativeRuntime").apply { start() }
        workerHandler = Handler(workerThread.looper) { message ->
            handleWorkerMessage(message)
            true
        }
        serviceMessenger = Messenger(workerHandler)
    }

    override fun onBind(intent: Intent?): IBinder = serviceMessenger.binder

    override fun onUnbind(intent: Intent?): Boolean {
        if (!stopRequested && startedToken != null) {
            stopRequested = true
            mainHandler.postDelayed({
                stopSelf()
                killPrivateProcess()
            }, STOP_ACK_DELAY_MS)
        }
        return false
    }

    override fun onStartCommand(intent: Intent?, flags: Int, startId: Int): Int =
        START_NOT_STICKY

    override fun onDestroy() {
        startupExecutor.shutdownNow()
        workerThread.quitSafely()
        super.onDestroy()
    }

    private fun handleWorkerMessage(message: Message) {
        val replyTo = message.replyTo
        when (message.what) {
            NativeRuntimeMessages.START -> startRuntime(message.data, replyTo)
            NativeRuntimeMessages.STOP -> stopRuntime(replyTo)
            else -> replyError(replyTo, "invalid_request", "Unknown native Runtime request.")
        }
    }

    private fun startRuntime(data: Bundle, replyTo: Messenger?) {
        if (replyTo == null) return
        val token = data.getString(NativeRuntimeMessages.TOKEN)?.trim().orEmpty()
        if (token.isEmpty()) {
            replyError(replyTo, "invalid_request", "The native Runtime token is missing.")
            return
        }

        val previousToken = startedToken
        val existingReadyJson = readyJson
        if (previousToken != null) {
            if (previousToken == token && existingReadyJson != null) {
                replyReady(replyTo, existingReadyJson)
            } else {
                replyError(replyTo, "runtime_busy", "The native Runtime is already starting.")
            }
            return
        }

        startedToken = token
        stopRequested = false
        val requestedRoot = data.getString(NativeRuntimeMessages.ROOT)
        startupExecutor.execute {
            try {
                val root = java.io.File(requestedRoot ?: java.io.File(filesDir, "mgread-native").path)
                val expectedRoot = java.io.File(filesDir, "mgread-native").canonicalFile
                if (root.canonicalFile != expectedRoot) {
                    throw IllegalArgumentException("The native Runtime data root is invalid.")
                }
                if (!expectedRoot.exists() && !expectedRoot.mkdirs()) {
                    throw IllegalStateException("The native Runtime data directory could not be created.")
                }
                val response = NativeRuntime.start(expectedRoot.canonicalPath, token)
                if (response.isBlank()) {
                    throw IllegalStateException("The native Runtime returned an empty ready response.")
                }
                workerHandler.post {
                    if (!stopRequested) {
                        readyJson = response
                        replyReady(replyTo, response)
                    }
                }
            } catch (error: Throwable) {
                workerHandler.post {
                    if (!stopRequested) {
                        // NativeRuntime.start can time out while its detached
                        // Rust serve thread is still alive. Never permit an
                        // in-process retry that could create a second listener;
                        // report the failure, then retire only this private
                        // service process after Binder has delivered it.
                        stopRequested = true
                        readyJson = null
                        Log.e(TAG, "Native Runtime startup failed.", error)
                        replyError(
                            replyTo,
                            "native_start_failed",
                            error.message?.take(MAX_ERROR_LENGTH)
                                ?: "The native Runtime could not be started.",
                        )
                        mainHandler.postDelayed({
                            stopSelf()
                            killPrivateProcess()
                        }, STOP_ACK_DELAY_MS)
                    }
                }
            }
        }
    }

    private fun stopRuntime(replyTo: Messenger?) {
        stopRequested = true
        if (replyTo != null) {
            runCatching {
                replyTo.send(Message.obtain(null, NativeRuntimeMessages.STOPPED))
            }
        }
        // Let Binder deliver the acknowledgement before terminating this
        // process. The app process and all its other services are unaffected.
        mainHandler.postDelayed({
            stopSelf()
            killPrivateProcess()
        }, STOP_ACK_DELAY_MS)
    }

    private fun replyReady(replyTo: Messenger, value: String) {
        val response = Message.obtain(null, NativeRuntimeMessages.READY)
        response.data = Bundle().apply { putString(NativeRuntimeMessages.READY_JSON, value) }
        sendReply(replyTo, response)
    }

    private fun replyError(replyTo: Messenger?, code: String, message: String) {
        if (replyTo == null) return
        val response = Message.obtain(null, NativeRuntimeMessages.ERROR)
        response.data = Bundle().apply {
            putString(NativeRuntimeMessages.ERROR_CODE, code)
            putString(NativeRuntimeMessages.ERROR_MESSAGE, message)
        }
        sendReply(replyTo, response)
    }

    private fun sendReply(replyTo: Messenger, response: Message) {
        runCatching { replyTo.send(response) }
            .onFailure { Log.w(TAG, "Native Runtime client disconnected before its reply.", it) }
    }

    private fun killPrivateProcess() {
        val expectedName = "${applicationInfo.processName ?: packageName}:mgread_native"
        val actualName = if (android.os.Build.VERSION.SDK_INT >= 28) {
            Application.getProcessName()
        } else {
            val manager = getSystemService(Context.ACTIVITY_SERVICE) as? ActivityManager
            manager?.runningAppProcesses
                ?.firstOrNull { it.pid == Process.myPid() }
                ?.processName
        }
        if (actualName == expectedName) {
            Process.killProcess(Process.myPid())
        } else {
            Log.e(TAG, "Refusing to terminate an unexpected Runtime service process.")
        }
    }

    private companion object {
        const val TAG = "MgReadNativeRuntime"
        const val MAX_ERROR_LENGTH = 256
        const val STOP_ACK_DELAY_MS = 200L
    }
}
