package com.mgread.mgread_plugin_runtime

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.os.Handler
import android.os.Looper
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.PluginRegistry

/** Flutter bridge for the Runtime-owned Android Javet adapter. */
class MgReadPluginRuntimePlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler, ActivityAware {
    private companion object {
        const val IMPORT_FILE_REQUEST = 48271
    }

    private val mainHandler = Handler(Looper.getMainLooper())
    private var channel: MethodChannel? = null
    private var progressChannel: EventChannel? = null
    private var progressSink: EventChannel.EventSink? = null
    private var runtime: AndroidRuntimeHost? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPickerResult: MethodChannel.Result? = null
    private val activityResultListener = object : PluginRegistry.ActivityResultListener {
        override fun onActivityResult(
            requestCode: Int,
            resultCode: Int,
            data: Intent?,
        ): Boolean {
            if (requestCode != IMPORT_FILE_REQUEST) return false
            val result = pendingPickerResult
            pendingPickerResult = null
            if (result == null) return true
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result.success(false)
                return true
            }
            val host = runtime
            if (host == null) {
                result.error("runtime_unavailable", "Android Runtime is not attached.", null)
                return true
            }
            host.importLocalPlugin(data.data.toString()) { error ->
                mainHandler.post {
                    if (error == null) {
                        result.success(true)
                    } else {
                        result.error(error.code, error.message, null)
                    }
                }
            }
            return true
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        val context = binding.applicationContext
        val assetRoot = binding.flutterAssets.getAssetFilePathByName(
            "packages/mgread_plugin_runtime/assets/runtime/android",
        )
        runtime = AndroidRuntimeHost(context, assetRoot) { progress ->
            mainHandler.post {
                progressSink?.success(
                    mapOf(
                        "completedBytes" to progress.completedBytes,
                        "detail" to progress.detail,
                        "stage" to progress.stage,
                        "totalBytes" to progress.totalBytes,
                    ),
                )
            }
        }
        channel = MethodChannel(
            binding.binaryMessenger,
            "mgread_plugin_runtime/android",
        ).also { it.setMethodCallHandler(this) }
        progressChannel = EventChannel(
            binding.binaryMessenger,
            "mgread_plugin_runtime/android/progress",
        ).also { it.setStreamHandler(this) }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        val host = runtime
        if (host == null) {
            result.error("runtime_unavailable", "Android Runtime is not attached.", null)
            return
        }
        when (call.method) {
            "invoke" -> {
                val method = call.argument<String>("method")
                val params = call.argument<Map<String, Any?>>("params") ?: emptyMap()
                val deadline = call.argument<Long>("deadlineUnixMs") ?: 0L
                if (method.isNullOrBlank() || deadline <= 0L) {
                    result.error("invalid_request", "Android Runtime request is invalid.", null)
                    return
                }
                host.invoke(method, params, deadline) { error, value ->
                    mainHandler.post {
                        if (error == null) {
                            result.success(value)
                        } else {
                            result.error(error.code, error.message, null)
                        }
                    }
                }
            }
            "importLocalPlugin" -> {
                val sourcePath = call.argument<String>("sourcePath")
                if (sourcePath.isNullOrBlank()) {
                    result.error("invalid_request", "The selected plugin archive is invalid.", null)
                    return
                }
                host.importLocalPlugin(sourcePath) { error ->
                    mainHandler.post {
                        if (error == null) {
                            result.success(null)
                        } else {
                            result.error(error.code, error.message, null)
                        }
                    }
                }
            }
            "pickAndImportLocalPlugin" -> {
                openPluginPicker(result)
            }
            "beginPluginTransfer" -> {
                val pluginId = call.argument<String>("pluginId")
                val version = call.argument<String>("version")
                val bytes = call.argument<Number>("bytes")?.toLong()
                val sha256 = call.argument<String>("sha256")
                val format = call.argument<String>("format")
                if (pluginId.isNullOrBlank() || version.isNullOrBlank() || bytes == null || sha256.isNullOrBlank() || format.isNullOrBlank()) {
                    result.error("invalid_request", "The plugin transfer metadata is invalid.", null)
                    return
                }
                host.beginPluginTransfer(pluginId, version, bytes, sha256, format) { error, id ->
                    mainHandler.post {
                        if (error == null) result.success(id) else result.error(error.code, error.message, null)
                    }
                }
            }
            "beginPluginTransferExport" -> {
                val pluginId = call.argument<String>("pluginId")
                val version = call.argument<String>("version")
                val format = call.argument<String>("format")
                if (pluginId.isNullOrBlank() || version.isNullOrBlank() || format.isNullOrBlank()) {
                    result.error("invalid_request", "The plugin export metadata is invalid.", null)
                    return
                }
                host.beginPluginTransferExport(pluginId, version, format) { error, metadata ->
                    mainHandler.post {
                        if (error == null) result.success(metadata) else result.error(error.code, error.message, null)
                    }
                }
            }
            "readPluginTransferExportChunk" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrBlank()) {
                    result.error("invalid_request", "The plugin export session is invalid.", null)
                    return
                }
                host.readPluginTransferExportChunk(id) { error, chunk ->
                    mainHandler.post {
                        if (error == null) result.success(chunk) else result.error(error.code, error.message, null)
                    }
                }
            }
            "cancelPluginTransferExport" -> {
                val id = call.argument<String>("id")
                if (id.isNullOrBlank()) {
                    result.error("invalid_request", "The plugin export session is invalid.", null)
                    return
                }
                host.cancelPluginTransferExport(id)
                result.success(null)
            }
            "writePluginTransferChunk" -> {
                val id = call.argument<String>("id")
                val chunk = call.argument<ByteArray>("chunk")
                if (id.isNullOrBlank() || chunk == null) {
                    result.error("invalid_request", "The plugin transfer chunk is invalid.", null)
                    return
                }
                host.writePluginTransferChunk(id, chunk) { error ->
                    mainHandler.post {
                        if (error == null) result.success(null) else result.error(error.code, error.message, null)
                    }
                }
            }
            "finishPluginTransferBatch" -> {
                val ids = call.argument<List<String>>("ids")
                if (ids.isNullOrEmpty()) {
                    result.error("invalid_request", "The plugin transfer batch is invalid.", null)
                    return
                }
                host.finishPluginTransferBatch(ids) { error ->
                    mainHandler.post {
                        if (error == null) result.success(null) else result.error(error.code, error.message, null)
                    }
                }
            }
            "dispose" -> {
                host.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        activityBinding?.removeActivityResultListener(activityResultListener)
        activityBinding = null
        pendingPickerResult?.error(
            "runtime_unavailable",
            "Android Runtime is not attached.",
            null,
        )
        pendingPickerResult = null
        channel?.setMethodCallHandler(null)
        channel = null
        progressChannel?.setStreamHandler(null)
        progressChannel = null
        progressSink = null
        runtime?.dispose()
        runtime = null
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
        pendingPickerResult?.error(
            "runtime_unavailable",
            "The Android file picker was detached.",
            null,
        )
        pendingPickerResult = null
    }

    private fun openPluginPicker(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null) {
            result.error("runtime_unavailable", "The Android file picker is unavailable.", null)
            return
        }
        if (pendingPickerResult != null) {
            result.error("busy", "A plugin file picker is already open.", null)
            return
        }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(
                Intent.EXTRA_MIME_TYPES,
                arrayOf(
                    "application/javascript",
                    "text/javascript",
                    "application/zip",
                    "application/octet-stream",
                ),
            )
        }
        pendingPickerResult = result
        try {
            activity.startActivityForResult(intent, IMPORT_FILE_REQUEST)
        } catch (error: Throwable) {
            pendingPickerResult = null
            result.error(
                "file_picker_unavailable",
                "The Android file picker could not be opened.",
                null,
            )
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        progressSink = events
    }

    override fun onCancel(arguments: Any?) {
        progressSink = null
    }
}
