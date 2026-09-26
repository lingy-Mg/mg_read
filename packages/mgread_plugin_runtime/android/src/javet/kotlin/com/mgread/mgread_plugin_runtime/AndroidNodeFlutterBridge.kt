/**
 * Main-process Flutter bridge for the opt-in Android Node service.
 *
 * Binder carries lifecycle records only. Plugin capabilities and resource
 * streams use Core's authenticated loopback protocol from Dart. This class
 * owns the main-process WebView, picker and bounded artifact inbox IO.
 */
package com.mgread.mgread_plugin_runtime

import android.app.Activity
import android.content.Context
import android.content.Intent
import android.net.Uri
import android.provider.OpenableColumns
import android.os.Handler
import android.os.Looper
import android.os.Build
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.PluginRegistry
import java.io.File
import java.io.FileOutputStream
import java.util.concurrent.Executors

internal class AndroidNodeFlutterBridge(
    private val context: Context,
    messenger: io.flutter.plugin.common.BinaryMessenger,
    assetRoot: String,
    private val backendGate: AndroidRuntimeBackendGate,
) : MethodChannel.MethodCallHandler, EventChannel.StreamHandler {
    private val main = Handler(Looper.getMainLooper())
    private val io = Executors.newSingleThreadExecutor { task ->
        Thread(task, "mgread-node-file-io").apply { isDaemon = true }
    }
    private val channel = MethodChannel(messenger, "mgread_plugin_runtime/android_node")
    private val events = EventChannel(messenger, "mgread_plugin_runtime/android_node/events")
    private var sink: EventChannel.EventSink? = null
    private var activityBinding: ActivityPluginBinding? = null
    private var pendingPicker: MethodChannel.Result? = null
    private val browser = AndroidBrowserSessionHost(context)
    private val dataRoot = File(context.filesDir, "mgread-runtime/data")
    private val transfer = AndroidPluginArtifactTransfer(File(dataRoot, "import-inbox"))
    private val process = AndroidNodeProcessController(context, assetRoot, ::progress, ::event)
    private val pickerListener = PluginRegistry.ActivityResultListener { requestCode, resultCode, data ->
        if (requestCode != PICKER_REQUEST) return@ActivityResultListener false
        val result = pendingPicker
        pendingPicker = null
        if (result != null) {
            if (resultCode == Activity.RESULT_OK && data?.data != null) {
                importSelected(data.data.toString(), result, asPicker = true)
            } else {
                result.success(false)
            }
        }
        true
    }

    init {
        channel.setMethodCallHandler(this)
        events.setStreamHandler(this)
    }

    fun attachActivity(binding: ActivityPluginBinding?) {
        activityBinding?.removeActivityResultListener(pickerListener)
        activityBinding = binding
        browser.attachActivity(binding?.activity)
        binding?.addActivityResultListener(pickerListener)
        if (binding == null) {
            pendingPicker?.error("runtime_unavailable", "The Android picker was detached.", null)
            pendingPicker = null
        }
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (call.method != "dispose" &&
            !backendGate.claim(AndroidRuntimeBackend.NODE_PROCESS)
        ) {
            result.error("runtime_backend_conflict", "Android Runtime backend is already selected.", null)
            return
        }
        when (call.method) {
            "start" -> {
                if (!Build.SUPPORTED_ABIS.contains("arm64-v8a")) {
                    result.error("unsupported", "Android Node process requires arm64-v8a.", null)
                } else process.start { error, ready -> finish(result, error, ready) }
            }
            "restart" -> {
                if (!Build.SUPPORTED_ABIS.contains("arm64-v8a")) {
                    result.error("unsupported", "Android Node process requires arm64-v8a.", null)
                } else process.restart { error, ready -> finish(result, error, ready) }
            }
            "browserStart" -> {
                val raw = call.argument<String>("request")
                if (raw == null) result.error("invalid_request", "Missing browser request.", null)
                else result.success(browser.start(raw))
            }
            "browserPoll" -> {
                val id = call.argument<String>("id")
                if (id == null) result.error("invalid_request", "Missing browser job.", null)
                else result.success(browser.poll(id))
            }
            "browserCancel" -> {
                call.argument<String>("id")?.let(browser::cancel)
                result.success(null)
            }
            "importLocal" -> {
                val path = call.argument<String>("sourcePath")
                if (path == null) result.error("invalid_request", "Missing plugin path.", null)
                else importSelected(path, result, asPicker = false)
            }
            "pickAndImportLocal" -> pick(result)
            "beginPluginTransfer" -> fileOperation(result) {
                transfer.beginImport(
                    required(call, "pluginId"), required(call, "version"),
                    call.argument<Number>("bytes")?.toLong() ?: error("invalid_request"),
                    required(call, "checksum"), required(call, "format"),
                )
            }
            "writePluginTransferChunk" -> fileOperation(result) {
                transfer.writeImportChunk(
                    required(call, "id"),
                    call.argument<ByteArray>("chunk") ?: error("invalid_request"),
                )
                null
            }
            "finishPluginTransferBatch" -> fileOperation(result) {
                val ids = call.argument<List<String>>("ids") ?: error("invalid_request")
                transfer.finishImportBatch(ids)
                main.post {
                    process.restart { error, _ -> finish(result, error, null) }
                }
                PENDING
            }
            "cancelPluginTransferBatch" -> fileOperation(result) {
                transfer.cancelImports(call.argument<List<String>>("ids") ?: error("invalid_request"))
                null
            }
            "beginPluginTransferExport" -> fileOperation(result) {
                transfer.beginExport(
                    dataRoot, required(call, "pluginId"),
                    required(call, "version"), required(call, "format"),
                )
            }
            "readPluginTransferExportChunk" -> fileOperation(result) {
                transfer.readExportChunk(required(call, "id"))
            }
            "cancelPluginTransferExport" -> fileOperation(result) {
                transfer.cancelExport(required(call, "id"))
                null
            }
            "dispose" -> {
                process.dispose()
                browser.dispose()
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    private fun required(call: MethodCall, key: String): String =
        call.argument<String>(key)?.takeIf { it.isNotEmpty() } ?: error("invalid_request")

    private fun fileOperation(result: MethodChannel.Result, action: () -> Any?) {
        io.execute {
            val value = runCatching(action)
            main.post {
                value.fold(
                    onSuccess = { if (it !== PENDING) result.success(it) },
                    onFailure = { result.error(fileErrorCode(it), "Android Node plugin IO failed.", null) },
                )
            }
        }
    }

    private fun fileErrorCode(error: Throwable): String {
        val allowed = setOf(
            "invalid_request", "file_unavailable", "file_unreadable", "file_too_large",
            "file_name_invalid", "disk_full", "plugin_transfer_artifact_missing",
            "plugin_transfer_artifact_too_large", "plugin_transfer_size_mismatch",
            "plugin_transfer_checksum_mismatch", "transfer_batch_too_large",
        )
        return error.message?.takeIf { it in allowed } ?: "file_read_failed"
    }

    private fun pick(result: MethodChannel.Result) {
        val activity = activityBinding?.activity
        if (activity == null || pendingPicker != null) {
            result.error("runtime_unavailable", "The Android picker is unavailable.", null)
            return
        }
        pendingPicker = result
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = "application/octet-stream"
            putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("application/javascript", "text/javascript", "application/zip", "application/octet-stream"))
        }
        runCatching { activity.startActivityForResult(intent, PICKER_REQUEST) }.onFailure {
            pendingPicker = null
            result.error("file_picker_unavailable", "The Android picker could not open.", null)
        }
    }

    private fun importSelected(sourcePath: String, result: MethodChannel.Result, asPicker: Boolean) {
        fileOperation(result) {
            val uri = Uri.parse(sourcePath)
            val name = if (uri.scheme == "content") {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.DISPLAY_NAME), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val column = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                            if (column >= 0) cursor.getString(column) else null
                        } else null
                    } ?: error("file_unavailable")
            } else File(if (uri.scheme == "file") uri.path.orEmpty() else sourcePath).name
            val suffix = when {
                name.endsWith(".mgplugin.js", ignoreCase = true) -> ".mgplugin.js"
                name.endsWith(".mgplugin", ignoreCase = true) -> ".mgplugin"
                else -> error("file_name_invalid")
            }
            val inbox = File(dataRoot, "import-inbox").apply { mkdirs() }
            val target = File(inbox, "import-${System.nanoTime()}$suffix")
            val temporary = File("${target.path}.part")
            val expectedBytes = if (uri.scheme == "content") {
                context.contentResolver.query(uri, arrayOf(OpenableColumns.SIZE), null, null, null)
                    ?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val column = cursor.getColumnIndex(OpenableColumns.SIZE)
                            if (column >= 0 && !cursor.isNull(column)) cursor.getLong(column) else 0L
                        } else 0L
                    } ?: 0L
            } else File(if (uri.scheme == "file") uri.path.orEmpty() else sourcePath).length()
            check(expectedBytes <= MAX_IMPORT_BYTES) { "file_too_large" }
            progress(AndroidRuntimeProgress(0, "plugin_copying", expectedBytes))
            try {
                val input = if (uri.scheme == "content") context.contentResolver.openInputStream(uri)
                    else File(if (uri.scheme == "file") uri.path.orEmpty() else sourcePath).inputStream()
                input?.use { source ->
                    FileOutputStream(temporary).use { output ->
                        val buffer = ByteArray(8192)
                        var count = 0L
                        var lastReported = 0L
                        while (true) {
                            val read = source.read(buffer)
                            if (read < 0) break
                            count += read
                            check(count <= MAX_IMPORT_BYTES) { "file_too_large" }
                            output.write(buffer, 0, read)
                            if (count - lastReported >= 256 * 1024L) {
                                lastReported = count
                                progress(AndroidRuntimeProgress(count, "plugin_copying", expectedBytes))
                            }
                        }
                        progress(AndroidRuntimeProgress(count, "plugin_copied", expectedBytes))
                    }
                } ?: error("file_unreadable")
                check(temporary.renameTo(target)) { "disk_full" }
            } finally {
                temporary.delete()
            }
            main.post {
                progress(AndroidRuntimeProgress(0, "plugin_installing", 0))
                process.restart { error, _ ->
                    if (error == null) result.success(if (asPicker) true else null)
                    else result.error(error.code, error.message, null)
                }
            }
            PENDING
        }
    }

    private fun finish(result: MethodChannel.Result, error: AndroidRuntimeError?, ready: String?) {
        if (error == null) result.success(ready) else result.error(error.code, error.message, null)
    }

    private fun progress(value: AndroidRuntimeProgress) {
        main.post {
            sink?.success(mapOf(
                "type" to "progress",
                "completedBytes" to value.completedBytes,
                "catalogState" to value.catalogState,
                "detail" to value.detail,
                "durationMicros" to value.durationMicros,
                "itemCount" to value.itemCount,
                "stage" to value.stage,
                "totalBytes" to value.totalBytes,
            ))
        }
    }

    private fun event(value: Map<String, Any?>) {
        main.post { sink?.success(value) }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink?) {
        sink = events
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    fun dispose() {
        attachActivity(null)
        channel.setMethodCallHandler(null)
        events.setStreamHandler(null)
        sink = null
        process.dispose()
        browser.dispose()
        io.shutdownNow()
    }

    private companion object {
        const val PICKER_REQUEST = 48272
        const val MAX_IMPORT_BYTES = 32L * 1024L * 1024L
        val PENDING = Any()
    }
}
