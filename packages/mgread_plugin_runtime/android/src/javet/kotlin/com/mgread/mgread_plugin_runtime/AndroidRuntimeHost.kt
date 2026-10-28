/** Android Runtime file/transfer facade. The engine owns its single VM,
 * callback lifecycle and event-driven wake pipe; this owner serializes artifact
 * IO on that thread and reports import completion only after Core activation.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.app.Activity
import android.net.Uri
import android.provider.OpenableColumns
import java.io.File
import java.io.FileOutputStream

internal data class AndroidRuntimeError(
    val code: String,
    override val message: String,
) : Exception(message)

internal data class AndroidRuntimeProgress(
    val completedBytes: Long,
    val stage: String,
    val totalBytes: Long,
    val detail: String? = null,
    val durationMicros: Long? = null,
    val itemCount: Long? = null,
    val catalogState: String? = null,
)

internal class AndroidRuntimeHost(
    private val context: Context,
    assetRoot: String,
    private val onProgress: (AndroidRuntimeProgress) -> Unit,
) {
    private val artifactTransfer = AndroidPluginArtifactTransfer(context)
    private val browserHost = AndroidBrowserSessionHost(context)
    private val engine = AndroidJavetEngine(context, assetRoot, browserHost, onProgress) { artifactTransfer.dispose() }

    fun attachActivity(activity: Activity?) = browserHost.attachActivity(activity)
    fun invoke(requestId: String, method: String, params: Map<String, Any?>, deadlineUnixMs: Long,
               callback: (AndroidRuntimeError?, String?) -> Unit) = engine.invoke(requestId, method, params, deadlineUnixMs, callback)
    fun cancelInvocation(requestId: String) = engine.cancel(requestId)
    fun dispose() = engine.dispose()

    fun importLocalPlugin(sourcePath: String, callback: (AndroidRuntimeError?) -> Unit) {
        engine.submit({ callback(it) }) {
            var temporary: File? = null
            var phase = "validate"
            try {
                val name = selectedFileName(sourcePath)
                val format = artifactFormatForName(name) ?: error("file_name_invalid")
                val inbox = File(context.filesDir, "mgread-runtime/data/import-inbox").apply { mkdirs() }
                val target = File(inbox, "import-${System.currentTimeMillis()}${artifactSuffix(format)}")
                val part = File(target.path + ".part")
                temporary = part
                phase = "read"
                val bytes = selectedFileSize(sourcePath)
                onProgress(AndroidRuntimeProgress(0, "plugin_copying", bytes))
                copySelectedFile(sourcePath, part) { copied -> onProgress(AndroidRuntimeProgress(copied, "plugin_copying", bytes)) }
                onProgress(AndroidRuntimeProgress(bytes, "plugin_copied", bytes))
                check(part.renameTo(target)) { "disk_full" }
                onProgress(AndroidRuntimeProgress(0, "plugin_installing", 0))
                engine.restartCore { error ->
                    if (error == null) callback(null)
                    else engine.recover { callback(AndroidRuntimeError("plugin_install_failed", "Android Runtime could not activate the imported plugin.")) }
                }
            } catch (error: Throwable) {
                temporary?.delete()
                val code = when (error.message) {
                    "file_name_invalid", "file_unavailable", "file_unreadable", "file_too_large", "invalid_request", "disk_full" -> error.message!!
                    else -> if (phase == "read") "file_read_failed" else "internal"
                }
                callback(AndroidRuntimeError(code, "Android Runtime could not import the selected plugin."))
            }
        }
    }

    fun beginPluginTransferBatch(artifacts: List<Map<String, Any?>>, callback: (AndroidRuntimeError?, Map<String, Any?>?) -> Unit) {
        engine.submit({ callback(it, null) }) {
            try { callback(null, artifactTransfer.beginImportBatch(artifacts)) }
            catch (error: Throwable) { callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android could not begin plugin import."), null) }
        }
    }

    fun beginPluginTransferExport(pluginId: String, version: String, format: String,
                                  callback: (AndroidRuntimeError?, Map<String, Any?>?) -> Unit) {
        engine.withCore { error ->
            if (error != null) callback(error, null)
            else try { callback(null, artifactTransfer.beginExport(engine.dataRoot ?: error("runtime_unavailable"), pluginId, version, format)) }
            catch (error: Throwable) { callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not export the plugin artifact."), null) }
        }
    }

    fun readPluginTransferExportChunk(id: String, callback: (AndroidRuntimeError?, ByteArray?) -> Unit) {
        engine.submit({ callback(it, null) }) {
            try { callback(null, artifactTransfer.readExportChunk(id)) }
            catch (error: Throwable) {
                artifactTransfer.cancelExport(id)
                callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not read the plugin artifact."), null)
            }
        }
    }

    fun cancelPluginTransferExport(id: String) { engine.submit({}) { artifactTransfer.cancelExport(id) } }

    fun finishPluginTransferBatch(id: String, callback: (AndroidRuntimeError?) -> Unit) {
        engine.submit({ callback(it) }) {
            try {
                artifactTransfer.finishImportBatch(id)
                engine.restartCore { error ->
                    if (error == null) callback(null)
                    else engine.recover { callback(AndroidRuntimeError("plugin_transfer_failed", "Android Runtime could not activate the plugin transfer.")) }
                }
            } catch (error: Throwable) {
                runCatching { artifactTransfer.cancelImportBatch(id) }
                val code = when (error.message) {
                    "plugin_transfer_size_mismatch", "plugin_transfer_checksum_mismatch", "transfer_batch_too_large", "disk_full" -> error.message!!
                    else -> "plugin_transfer_failed"
                }
                callback(AndroidRuntimeError(code, "Android Runtime could not finalize plugin transfer."))
            }
        }
    }

    fun cancelPluginTransferBatch(id: String, callback: (AndroidRuntimeError?) -> Unit) {
        engine.submit({ callback(it) }) {
            try { artifactTransfer.cancelImportBatch(id); callback(null) }
            catch (_: Throwable) { callback(AndroidRuntimeError("plugin_transfer_failed", "Android Runtime could not cancel plugin transfer.")) }
        }
    }

    private fun selectedFileName(sourcePath: String): String {
        if (!isContentUri(sourcePath)) return localFile(sourcePath).name
        val uri = Uri.parse(sourcePath)
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.DISPLAY_NAME),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.DISPLAY_NAME)
                if (index >= 0) return cursor.getString(index).orEmpty()
            }
        }
        return Uri.decode(uri.lastPathSegment.orEmpty())
    }

    private fun selectedFileSize(sourcePath: String): Long {
        if (!isContentUri(sourcePath)) return localFile(sourcePath).length().coerceAtLeast(0L)
        val uri = Uri.parse(sourcePath)
        context.contentResolver.query(
            uri,
            arrayOf(OpenableColumns.SIZE),
            null,
            null,
            null,
        )?.use { cursor ->
            if (cursor.moveToFirst()) {
                val index = cursor.getColumnIndex(OpenableColumns.SIZE)
                if (index >= 0 && !cursor.isNull(index)) {
                    return cursor.getLong(index).coerceAtLeast(0L)
                }
            }
        }
        return 0L
    }

    private fun copySelectedFile(
        sourcePath: String,
        destination: File,
        onCopied: (Long) -> Unit,
    ) {
        val input = if (isContentUri(sourcePath)) {
            context.contentResolver.openInputStream(Uri.parse(sourcePath))
        } else {
            val source = localFile(sourcePath)
            check(source.isFile) { "file_unavailable" }
            source.inputStream()
        } ?: error("file_unreadable")
        input.use { source ->
            FileOutputStream(destination).use { target ->
                val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                var total = 0L
                var lastReported = 0L
                while (true) {
                    val read = source.read(buffer)
                    if (read < 0) break
                    total += read
                    check(total <= MAX_IMPORT_BYTES) { "file_too_large" }
                    target.write(buffer, 0, read)
                    if (total - lastReported >= PROGRESS_REPORT_BYTES) {
                        lastReported = total
                        onCopied(total)
                    }
                }
                onCopied(total)
            }
        }
    }

    private fun isContentUri(sourcePath: String): Boolean =
        sourcePath.startsWith("content://", ignoreCase = true)

    private fun localFile(sourcePath: String): File {
        if (sourcePath.startsWith("file://", ignoreCase = true)) {
            return File(Uri.parse(sourcePath).path.orEmpty())
        }
        return File(sourcePath)
    }

    private companion object {
        const val MAX_IMPORT_BYTES = 32L * 1024L * 1024L
        const val PROGRESS_REPORT_BYTES = 64L * 1024L
    }
    private fun artifactFormatForName(name: String): String? = when {
        name.endsWith(".mgplugin.js", ignoreCase = true) -> "singleFile"
        name.endsWith(".mgplugin", ignoreCase = true) -> "archive"
        else -> null
    }

    private fun artifactSuffix(format: String): String = when (format) {
        "singleFile" -> ".mgplugin.js"
        "archive" -> ".mgplugin"
        else -> error("invalid_request")
    }
}
