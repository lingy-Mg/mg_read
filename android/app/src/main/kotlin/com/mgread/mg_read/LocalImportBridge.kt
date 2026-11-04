package com.mgread.mg_read

import android.app.Activity
import android.content.Intent
import android.net.Uri
import android.os.Handler
import android.os.Looper
import android.os.Build
import android.provider.DocumentsContract
import io.flutter.plugin.common.BinaryMessenger
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import java.io.InputStream
import java.io.OutputStream
import java.util.UUID
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.Executors

/**
 * Android SAF ingress for TXT/EPUB and incoming ACTION_VIEW/SEND files.
 * The Dart side receives opaque tokens and reads <=256 KiB at a time; URI
 * grants and streams stay native and no path or whole-file byte array crosses.
 * MainActivity should install this bridge, forward onActivityResult/onNewIntent,
 * and call drainPending after Dart registers its method handler.
 */
class LocalImportBridge private constructor(
    private val activity: Activity,
    messenger: BinaryMessenger,
) : MethodChannel.MethodCallHandler {
    private val channel = MethodChannel(messenger, CHANNEL)
    private val worker = Executors.newSingleThreadExecutor()
    private val handles = ConcurrentHashMap<String, Handle>()
    private var pendingPick: MethodChannel.Result? = null
    private var pendingExport: MethodChannel.Result? = null

    data class Handle(
        val uri: Uri,
        val name: String,
        val bytes: Long?,
        var stream: InputStream? = null,
        var output: OutputStream? = null,
    )

    init { channel.setMethodCallHandler(this) }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "pickFiles" -> pick(call.argument<String>("kind") ?: "documents", result)
            "createExport" -> createExport(call, result)
            "readChunk" -> readChunk(call, result)
            "writeChunk" -> writeChunk(call, result)
            "finishExport" -> finishExport(call, result)
            "close" -> {
                val token = call.argument<String>("token")
                if (token != null) close(token)
                result.success(null)
            }
            "release" -> {
                val token = call.argument<String>("token")
                if (token != null) release(token)
                result.success(null)
            }
            "drainPending" -> result.success(drainPayload())
            else -> result.notImplemented()
        }
    }

    private fun pick(kind: String, result: MethodChannel.Result) {
        if (pendingPick != null) { result.error("picker_busy", "A file picker is already open", null); return }
        val intent = Intent(Intent.ACTION_OPEN_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = if (kind == "image") "image/*" else "*/*"
            putExtra(Intent.EXTRA_ALLOW_MULTIPLE, true)
            if (kind != "image") putExtra(Intent.EXTRA_MIME_TYPES, arrayOf("text/plain", "application/epub+zip", "application/octet-stream"))
        }
        pendingPick = result
        try {
            activity.startActivityForResult(intent, PICK_REQUEST)
        } catch (error: Exception) {
            pendingPick = null
            result.error("picker_unavailable", error.javaClass.simpleName, null)
        }
    }

    private fun createExport(call: MethodCall, result: MethodChannel.Result) {
        if (pendingPick != null || pendingExport != null) {
            result.error("picker_busy", "A file picker is already open", null)
            return
        }
        val fileName = call.argument<String>("fileName")?.takeLast(180) ?: "MgRead-export.txt"
        val mimeType = call.argument<String>("mimeType") ?: "application/octet-stream"
        val intent = Intent(Intent.ACTION_CREATE_DOCUMENT).apply {
            addCategory(Intent.CATEGORY_OPENABLE)
            type = mimeType
            putExtra(Intent.EXTRA_TITLE, fileName)
        }
        pendingExport = result
        try {
            activity.startActivityForResult(intent, EXPORT_REQUEST)
        } catch (error: Exception) {
            pendingExport = null
            result.error("export_picker_unavailable", error.javaClass.simpleName, null)
        }
    }

    fun onActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean {
        if (requestCode == EXPORT_REQUEST) {
            val result = pendingExport ?: return true
            pendingExport = null
            if (resultCode != Activity.RESULT_OK || data?.data == null) {
                result.success(null)
                return true
            }
            val uri = data.data!!
            val token = UUID.randomUUID().toString()
            val name = queryName(uri) ?: "MgRead-export"
            handles[token] = Handle(uri, name, null)
            result.success(mapOf("token" to token, "name" to name))
            return true
        }
        if (requestCode != PICK_REQUEST) return false
        val result = pendingPick ?: return true
        pendingPick = null
        if (resultCode != Activity.RESULT_OK || data == null) { result.success(emptyList<Any>()); return true }
        val uris = mutableListOf<Uri>()
        data.data?.let(uris::add)
        data.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }
        worker.execute {
            val payload = uris.distinct().take(MAX_PENDING).map(::createHandle)
            Handler(Looper.getMainLooper()).post { result.success(payload) }
        }
        return true
    }

    fun onNewIntent(intent: Intent?) {
        if (intent == null) return
        val uris = collectUris(intent)
        if (uris.isNotEmpty()) {
          worker.execute {
            val payload = uris.distinct().take(MAX_PENDING).map(::createHandle)
            synchronized(pending) {
                val space = (MAX_PENDING - pending.size).coerceAtLeast(0)
                pending.addAll(payload.take(space))
                payload.drop(space).forEach { entry -> (entry["token"] as? String)?.let(::release) }
                val accepted = payload.take(space)
                Handler(Looper.getMainLooper()).post {
                    if (!worker.isShutdown) channel.invokeMethod("filesOpened", accepted)
                }
            }
          }
        }
    }

    @Suppress("DEPRECATION")
    private fun collectUris(intent: Intent): List<Uri> {
        val uris = mutableListOf<Uri>()
        intent.data?.let(uris::add)
        intent.clipData?.let { clip -> for (i in 0 until clip.itemCount) clip.getItemAt(i).uri?.let(uris::add) }
        try {
            when (intent.action) {
                Intent.ACTION_SEND -> {
                    val value = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    else intent.getParcelableExtra<Uri>(Intent.EXTRA_STREAM)
                    value?.let(uris::add)
                }
                Intent.ACTION_SEND_MULTIPLE -> {
                    val values = if (Build.VERSION.SDK_INT >= 33) intent.getParcelableArrayListExtra(Intent.EXTRA_STREAM, Uri::class.java)
                    else intent.getParcelableArrayListExtra<Uri>(Intent.EXTRA_STREAM)
                    values?.let(uris::addAll)
                }
            }
        } catch (_: Exception) { }
        return uris.distinct().take(MAX_PENDING)
    }

    private fun createHandle(uri: Uri): Map<String, Any?> {
        var name = "本地文件"
        var size: Long? = null
        // Metadata queries can contact a cloud provider; this method is called
        // only on the bounded worker, never on the Activity's UI thread.
        try {
            activity.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME, android.provider.OpenableColumns.SIZE), null, null, null)?.use { cursor ->
                if (cursor.moveToFirst()) {
                    if (!cursor.isNull(0)) name = cursor.getString(0)
                    if (!cursor.isNull(1)) size = cursor.getLong(1).takeIf { it >= 0 }
                }
            }
        } catch (_: Exception) { }
        val token = UUID.randomUUID().toString()
        handles[token] = Handle(uri, name, size)
        return mapOf("token" to token, "name" to name, "bytes" to size)
    }

    private fun readChunk(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val requested = call.argument<Int>("maxBytes") ?: MAX_CHUNK
        val maxBytes = requested.coerceIn(1, MAX_CHUNK)
        val handle = token?.let(handles::get)
        if (token == null || handle == null) { result.error("source_missing", "File handle is no longer available", null); return }
        worker.execute {
            try {
                val stream = handle.stream ?: activity.contentResolver.openInputStream(handle.uri)?.also { handle.stream = it }
                    ?: throw IllegalStateException("Cannot open selected file")
                val buffer = ByteArray(maxBytes)
                val count = stream.read(buffer)
                val bytes = if (count <= 0) ByteArray(0) else buffer.copyOf(count)
                Handler(Looper.getMainLooper()).post { result.success(mapOf("data" to bytes, "eof" to (count <= 0))) }
            } catch (error: Exception) {
                Handler(Looper.getMainLooper()).post { result.error("source_read_failed", error.javaClass.simpleName, null) }
            }
        }
    }

    private fun close(token: String) {
        val handle = handles[token] ?: return
        worker.execute {
            try { handle.stream?.close() } catch (_: Exception) { }
            handle.stream = null
        }
    }

    private fun writeChunk(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val bytes = call.argument<ByteArray>("data")
        val handle = token?.let(handles::get)
        if (handle == null || bytes == null || bytes.size > MAX_CHUNK || handle.uri.scheme == null) {
            result.error("export_write_invalid", "Invalid export chunk", null)
            return
        }
        worker.execute {
            try {
                val output = handle.output ?: activity.contentResolver.openOutputStream(handle.uri, "w")?.also { handle.output = it }
                    ?: throw IllegalStateException("Cannot open destination")
                output.write(bytes)
                Handler(Looper.getMainLooper()).post { result.success(null) }
            } catch (error: Exception) {
                Handler(Looper.getMainLooper()).post { result.error("export_write_failed", error.javaClass.simpleName, null) }
            }
        }
    }

    private fun finishExport(call: MethodCall, result: MethodChannel.Result) {
        val token = call.argument<String>("token")
        val handle = token?.let(handles::remove)
        if (handle == null) { result.error("export_missing", "Export destination is no longer available", null); return }
        worker.execute {
            try {
                if (call.argument<Boolean>("success") == true) handle.output?.flush()
                handle.output?.close()
                if (call.argument<Boolean>("success") != true) {
                    try { DocumentsContract.deleteDocument(activity.contentResolver, handle.uri) } catch (_: Exception) { }
                }
                Handler(Looper.getMainLooper()).post { result.success(null) }
            } catch (error: Exception) {
                Handler(Looper.getMainLooper()).post { result.error("export_finish_failed", error.javaClass.simpleName, null) }
            }
        }
    }

    private fun release(token: String) {
        val handle = handles.remove(token) ?: return
        worker.execute { try { handle.stream?.close() } catch (_: Exception) { } }
    }

    private fun queryName(uri: Uri): String? = try {
        activity.contentResolver.query(uri, arrayOf(android.provider.OpenableColumns.DISPLAY_NAME), null, null, null)?.use { cursor ->
            if (cursor.moveToFirst()) cursor.getString(0) else null
        }
    } catch (_: Exception) { null }

    private fun drainPayload(): List<Map<String, Any?>> = synchronized(pending) { pending.toList().also { pending.clear() } }

    fun shutdown() {
        channel.setMethodCallHandler(null)
        pendingPick?.error("activity_closed", "Activity closed during file selection", null)
        pendingPick = null
        pendingExport?.error("activity_closed", "Activity closed during export", null)
        pendingExport = null
        handles.values.forEach { handle ->
            try { handle.stream?.close() } catch (_: Exception) { }
            try { handle.output?.close() } catch (_: Exception) { }
        }
        handles.clear()
        synchronized(pending) {
            pending.clear()
        }
        worker.shutdownNow()
    }

    companion object {
        const val CHANNEL = "mg_read/local_import"
        const val PICK_REQUEST = 7431
        const val EXPORT_REQUEST = 7432
        const val MAX_CHUNK = 256 * 1024
        const val MAX_PENDING = 100
        private val pending = mutableListOf<Map<String, Any?>>()
        @Volatile private var instance: LocalImportBridge? = null

        fun install(activity: Activity, messenger: BinaryMessenger): LocalImportBridge {
            instance?.shutdown()
            return LocalImportBridge(activity, messenger).also { instance = it }
        }

        fun forwardInitialIntent(intent: Intent?) { instance?.onNewIntent(intent) }

        fun forwardActivityResult(requestCode: Int, resultCode: Int, data: Intent?): Boolean =
            instance?.onActivityResult(requestCode, resultCode, data) ?: false

        fun forwardNewIntent(intent: Intent?) { instance?.onNewIntent(intent) }

        fun shutdown(activity: Activity) {
            val current = instance ?: return
            if (current.activity !== activity) return
            current.shutdown()
            instance = null
        }
    }
}
