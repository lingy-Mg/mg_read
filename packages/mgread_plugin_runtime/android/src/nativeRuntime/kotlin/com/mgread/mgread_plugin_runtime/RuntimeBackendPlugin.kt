/**
 * Flutter bridge for the Android native-only Runtime variant.
 *
 * Owns the app-side Binder connection and system plugin picker. Rust owns
 * Runtime HTTP and source execution in the private service process.
 */
package com.mgread.mgread_plugin_runtime

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.database.Cursor
import android.net.Uri
import android.os.Bundle
import android.os.Handler
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.provider.OpenableColumns
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import org.json.JSONObject
import java.io.File
import java.io.IOException
import java.util.UUID
import java.util.concurrent.Executors

class NativeRuntimeBackendPlugin : FlutterPlugin, MethodChannel.MethodCallHandler, ActivityAware {
    private val mainHandler = Handler(Looper.getMainLooper())
    private var ioExecutor = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "MgReadNativeFiles").apply { isDaemon = true }
    }
    private var applicationContext: Context? = null
    private var channel: MethodChannel? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var serviceMessenger: Messenger? = null
    private var isBound = false
    private var pendingStart: MethodChannel.Result? = null
    private var pendingStartToken: String? = null
    private var pendingStop: MethodChannel.Result? = null
    private var pendingPicker: MethodChannel.Result? = null
    private var pickerGeneration = 0L
    private var ready: Map<String, Any>? = null
    private var readyToken: String? = null
    private var stopping = false
    private var pendingStopAcknowledged = false
    private var startTimeout: Runnable? = null
    private var stopTimeout: Runnable? = null

    private val clientMessenger = Messenger(
        Handler(Looper.getMainLooper()) { message ->
            handleServiceReply(message)
            true
        },
    )

    private val serviceConnection = object : android.content.ServiceConnection {
        override fun onServiceConnected(name: android.content.ComponentName, binder: android.os.IBinder) {
            serviceMessenger = Messenger(binder)
            val token = pendingStartToken
            if (token == null) {
                requestWorkerStop()
                return
            }
            val context = applicationContext ?: run {
                failPendingStart("runtime_unavailable", "The native Runtime plugin was detached.")
                return
            }
            val root = File(context.filesDir, "mgread-native")
            val data = Bundle().apply {
                putString(NativeRuntimeMessages.TOKEN, token)
                putString(NativeRuntimeMessages.ROOT, root.absolutePath)
            }
            if (!sendToService(NativeRuntimeMessages.START, data)) {
                failPendingStart("native_service_unavailable", "The native Runtime service did not accept startup.")
            }
        }

        override fun onServiceDisconnected(name: android.content.ComponentName) {
            serviceMessenger = null
            val stoppedResult = pendingStop
            pendingStop = null
            clearStopTimeout()
            if (pendingStart != null) {
                failPendingStart("native_worker_died", "The native Runtime worker exited during startup.")
            }
            ready = null
            readyToken = null
            stopping = false
            pendingStopAcknowledged = false
            unbindService()
            stoppedResult?.success(null)
        }

        override fun onBindingDied(name: android.content.ComponentName) {
            onServiceDisconnected(name)
            unbindService()
        }

        override fun onNullBinding(name: android.content.ComponentName) {
            onServiceDisconnected(name)
            unbindService()
        }
    }

    private val activityResultListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
        if (requestCode != PICKER_REQUEST) {
            false
        } else {
            handlePickerResult(resultCode, data?.data)
            true
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        applicationContext = binding.applicationContext
        if (ioExecutor.isShutdown) {
            ioExecutor = Executors.newSingleThreadExecutor { runnable ->
                Thread(runnable, "MgReadNativeFiles").apply { isDaemon = true }
            }
        }
        channel = MethodChannel(binding.binaryMessenger, CHANNEL).also { it.setMethodCallHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "start" -> start(call.argument<String>("token"), result)
            "stop" -> stop(result)
            "pickPlugin" -> pickPlugin(result)
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
        failPendingStart("runtime_unavailable", "The native Runtime plugin was detached.")
        finishPendingPickerError("runtime_unavailable", "The plugin picker was detached.")
        pendingStop?.let { result ->
            runCatching {
                result.error(
                    "native_stop_unconfirmed",
                    "The native Runtime plugin detached before worker shutdown was confirmed.",
                    null,
                )
            }
        }
        pendingStop = null
        clearTimeouts()
        val context = applicationContext
        if (serviceMessenger != null) {
            requestWorkerStop()
            if (isBound && context != null) {
                mainHandler.postDelayed({ unbindService(context) }, DETACH_STOP_DELAY_MS)
            }
        } else {
            unbindService()
        }
        channel?.setMethodCallHandler(null)
        channel = null
        applicationContext = null
        ready = null
        readyToken = null
        ioExecutor.shutdown()
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(activityResultListener)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activityBinding = binding
        binding.addActivityResultListener(activityResultListener)
    }

    override fun onDetachedFromActivity() {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
        finishPendingPickerError("runtime_unavailable", "The Android file picker was detached.")
    }

    private fun start(tokenArgument: String?, result: MethodChannel.Result) {
        val token = tokenArgument?.trim().orEmpty()
        if (token.isEmpty()) {
            result.error("invalid_request", "The native Runtime token is missing.", null)
            return
        }
        val currentReady = ready
        if (currentReady != null) {
            if (readyToken == token) result.success(currentReady)
            else result.error("runtime_busy", "The native Runtime is already running.", null)
            return
        }
        if (pendingStart != null || pendingStop != null || stopping) {
            result.error("busy", "A native Runtime lifecycle request is already active.", null)
            return
        }
        val context = applicationContext
        if (context == null) {
            result.error("runtime_unavailable", "The native Runtime plugin is not attached.", null)
            return
        }

        pendingStart = result
        pendingStartToken = token
        stopping = false
        val timeout = Runnable {
            if (pendingStart != null) {
                failPendingStart("native_start_timeout", "The native Runtime did not become ready in time.")
                requestWorkerStop()
            }
        }
        startTimeout = timeout
        mainHandler.postDelayed(timeout, START_TIMEOUT_MS)
        val bound = runCatching {
            context.bindService(
                Intent(context, NativeRuntimeService::class.java),
                serviceConnection,
                Context.BIND_AUTO_CREATE,
            )
        }.getOrDefault(false)
        if (!bound) {
            failPendingStart("native_service_unavailable", "The native Runtime service could not be bound.")
            return
        }
        isBound = true
    }

    private fun stop(result: MethodChannel.Result) {
        if (pendingStart != null) {
            result.error("busy", "The native Runtime is still starting.", null)
            return
        }
        if (pendingStop != null) {
            result.error("busy", "A native Runtime stop is already in progress.", null)
            return
        }
        if (serviceMessenger == null) {
            if (isBound) {
                // Binding may still be in progress after a timed-out start.
                // Keep this stop pending; onServiceConnected sees the missing
                // start token, sends STOP, and only process disconnection can
                // resolve the call successfully.
                stopping = true
                pendingStop = result
                pendingStopAcknowledged = false
                val timeout = Runnable { finishPendingStop() }
                stopTimeout = timeout
                mainHandler.postDelayed(timeout, STOP_TIMEOUT_MS)
                return
            }
            ready = null
            readyToken = null
            stopping = false
            pendingStopAcknowledged = false
            clearStopTimeout()
            unbindService()
            result.success(null)
            return
        }
        stopping = true
        pendingStop = result
        pendingStopAcknowledged = false
        val timeout = Runnable { finishPendingStop() }
        stopTimeout = timeout
        mainHandler.postDelayed(timeout, STOP_TIMEOUT_MS)
        sendToService(NativeRuntimeMessages.STOP)
    }

    private fun pickPlugin(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("runtime_unavailable", "The Android file picker is unavailable.", null)
            return
        }
        if (pendingPicker != null) {
            result.error("busy", "A plugin file picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/zip", "application/octet-stream"))
        }
        pendingPicker = result
        pickerGeneration += 1
        try {
            activity.startActivityForResult(intent, PICKER_REQUEST)
        } catch (_: Throwable) {
            pendingPicker = null
            result.error("file_picker_unavailable", "The Android file picker could not be opened.", null)
        }
    }

    private fun handlePickerResult(resultCode: Int, uri: Uri?) {
        val result = pendingPicker ?: return
        if (resultCode != Activity.RESULT_OK || uri == null) {
            pendingPicker = null
            result.success(null)
            return
        }
        val context = applicationContext
        if (context == null) {
            pendingPicker = null
            result.error("runtime_unavailable", "The Android Runtime plugin is not attached.", null)
            return
        }
        val generation = pickerGeneration
        val queued = runCatching {
            ioExecutor.execute {
                try {
                    val path = copyPluginToPrivateInbox(context, uri)
                    mainHandler.post {
                        if (generation == pickerGeneration && pendingPicker === result) {
                            pendingPicker = null
                            result.success(mapOf("path" to path))
                        }
                    }
                } catch (error: Throwable) {
                    mainHandler.post {
                        if (generation == pickerGeneration && pendingPicker === result) {
                            pendingPicker = null
                            result.error(
                                if (error is PluginFileTooLargeException) "plugin_too_large" else "plugin_import_failed",
                                error.message ?: "The selected plugin could not be copied.",
                                null,
                            )
                        }
                    }
                }
            }
        }
        queued.onFailure { error ->
            if (generation == pickerGeneration && pendingPicker === result) {
                pendingPicker = null
                result.error("plugin_import_failed", error.message ?: "The selected plugin could not be copied.", null)
            }
        }
    }

    private fun copyPluginToPrivateInbox(context: Context, uri: Uri): String {
        val inbox = File(context.filesDir, "mgread-native/inbox")
        if (!inbox.exists() && !inbox.mkdirs()) {
            throw IOException("The native plugin inbox could not be created.")
        }
        val originalName = displayName(context, uri)
        val safeName = originalName
            .substringAfterLast('/')
            .substringAfterLast('\\')
            .replace(Regex("[^A-Za-z0-9._-]"), "_")
            .take(MAX_FILE_NAME_LENGTH)
            .ifBlank { "plugin.mgplugin" }
        val id = UUID.randomUUID().toString()
        val temporary = File(inbox, ".$id.part")
        val destination = File(inbox, "$id-$safeName")
        try {
            val input = context.contentResolver.openInputStream(uri)
                ?: throw IOException("The selected plugin file could not be opened.")
            input.use { source ->
                temporary.outputStream().buffered().use { output ->
                    val buffer = ByteArray(COPY_BUFFER_SIZE)
                    var total = 0L
                    while (true) {
                        val read = source.read(buffer)
                        if (read < 0) break
                        total += read
                        if (total > MAX_PLUGIN_BYTES) throw PluginFileTooLargeException()
                        output.write(buffer, 0, read)
                    }
                    if (total == 0L) throw IOException("The selected plugin file is empty.")
                }
            }
            if (!temporary.renameTo(destination)) {
                throw IOException("The selected plugin could not be saved in the native inbox.")
            }
            return destination.canonicalPath
        } finally {
            temporary.delete()
        }
    }

    private fun displayName(context: Context, uri: Uri): String {
        var cursor: Cursor? = null
        return try {
            cursor = context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
            if (cursor != null && cursor.moveToFirst()) {
                val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (column >= 0) cursor.getString(column).orEmpty() else "plugin.mgplugin"
            } else {
                "plugin.mgplugin"
            }
        } finally {
            cursor?.close()
        }
    }

    private fun sendToService(what: Int, data: Bundle = Bundle()): Boolean {
        val messenger = serviceMessenger ?: return false
        val message = Message.obtain(null, what).apply {
            this.data = data
            replyTo = clientMessenger
        }
        return runCatching { messenger.send(message) }.isSuccess
    }

    private fun handleServiceReply(message: Message) {
        when (message.what) {
            NativeRuntimeMessages.READY -> {
                val encoded = message.data.getString(NativeRuntimeMessages.READY_JSON)
                val result = pendingStart ?: return
                try {
                    val response = JSONObject(encoded ?: throw IllegalArgumentException("Ready response is missing."))
                    val port = response.optInt("port", 0)
                    val token = response.optString("token")
                    val kind = response.optString("runtimeKind")
                    if (port !in 1..65535 || token != pendingStartToken || kind != RUNTIME_KIND) {
                        throw IllegalArgumentException("The native Runtime ready response is invalid.")
                    }
                    val value = mapOf("port" to port, "token" to token, "runtimeKind" to kind)
                    ready = value
                    readyToken = token
                    pendingStart = null
                    pendingStartToken = null
                    clearStartTimeout()
                    result.success(value)
                } catch (error: Throwable) {
                    failPendingStart("native_start_failed", error.message ?: "The native Runtime returned invalid readiness data.")
                    requestWorkerStop()
                }
            }
            NativeRuntimeMessages.ERROR -> {
                val code = message.data.getString(NativeRuntimeMessages.ERROR_CODE) ?: "native_start_failed"
                val detail = message.data.getString(NativeRuntimeMessages.ERROR_MESSAGE)
                    ?: "The native Runtime could not be started."
                failPendingStart(code, detail)
                requestWorkerStop()
            }
            NativeRuntimeMessages.STOPPED -> pendingStopAcknowledged = true
        }
    }

    private fun failPendingStart(code: String, message: String) {
        clearStartTimeout()
        val result = pendingStart
        pendingStart = null
        pendingStartToken = null
        result?.error(code, message, null)
        ready = null
        readyToken = null
    }

    private fun finishPendingStop() {
        clearStopTimeout()
        val result = pendingStop
        pendingStop = null
        result?.error(
            "native_stop_unconfirmed",
            if (pendingStopAcknowledged) {
                "The native Runtime service acknowledged stop but did not exit."
            } else {
                "The native Runtime service did not confirm that it stopped."
            },
            null,
        )
    }

    private fun requestWorkerStop() {
        stopping = true
        sendToService(NativeRuntimeMessages.STOP)
    }

    private fun finishPendingPickerError(code: String, message: String) {
        pickerGeneration += 1
        val result = pendingPicker
        pendingPicker = null
        result?.error(code, message, null)
    }

    private fun unbindService() {
        unbindService(applicationContext ?: return)
    }

    private fun unbindService(context: Context) {
        if (!isBound) return
        isBound = false
        serviceMessenger = null
        runCatching { context.unbindService(serviceConnection) }
    }

    private fun clearStartTimeout() {
        startTimeout?.let(mainHandler::removeCallbacks)
        startTimeout = null
    }

    private fun clearStopTimeout() {
        stopTimeout?.let(mainHandler::removeCallbacks)
        stopTimeout = null
    }

    private fun clearTimeouts() {
        clearStartTimeout()
        clearStopTimeout()
    }

    private class PluginFileTooLargeException : IOException("Plugin archives may not exceed 64 MiB.")

    private companion object {
        const val CHANNEL = "mgread/native_runtime"
        const val RUNTIME_KIND = "native-rust"
        const val PICKER_REQUEST = 48272
        const val START_TIMEOUT_MS = 30_000L
        const val STOP_TIMEOUT_MS = 2_000L
        const val DETACH_STOP_DELAY_MS = 300L
        const val MAX_PLUGIN_BYTES = 64L * 1024 * 1024
        const val COPY_BUFFER_SIZE = 16 * 1024
        const val MAX_FILE_NAME_LENGTH = 120
    }
}
