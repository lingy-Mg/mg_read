/**
 * Android Runtime host.
 *
 * Owns the single Javet NodeRuntime, its HandlerThread, and the bounded event-loop pump.
 * Flutter only receives typed capability results through the package bridge.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.net.Uri
import android.content.pm.ApplicationInfo
import android.provider.OpenableColumns
import android.util.Log
import com.caoccao.javet.enums.V8AwaitMode
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.V8Host
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8Module
import com.caoccao.javet.values.reference.V8ValueFunction
import com.caoccao.javet.values.reference.V8ValuePromise
import org.json.JSONObject
import java.io.File
import java.security.MessageDigest
import java.util.UUID
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean
import android.os.HandlerThread

internal data class AndroidRuntimeError(
    val code: String,
    override val message: String,
) : Exception(message)

internal data class AndroidRuntimeProgress(
    val completedBytes: Long,
    val stage: String,
    val totalBytes: Long,
    val detail: String? = null,
)

/** Owns one Javet NodeRuntime and all of its calls on one background thread. */
internal class AndroidRuntimeHost(
    private val context: Context,
    private val assetRoot: String,
    private val onProgress: (AndroidRuntimeProgress) -> Unit,
) {
    private val thread = HandlerThread("mgread-node-runtime").apply { start() }
    private val handler = android.os.Handler(thread.looper)
    private val disposed = AtomicBoolean(false)
    private var nodeRuntime: NodeRuntime? = null
    private var eventLoopPumpActive = false
    private val eventLoopPump = object : Runnable {
        override fun run() {
            if (!eventLoopPumpActive || disposed.get()) return
            val runtime = nodeRuntime
            if (runtime == null) return
            runCatching {
                // The persistent Runtime HTTP listener can receive work after a
                // Flutter invocation returns. Keep its sole Javet event loop
                // alive without blocking this HandlerThread's command queue.
                runtime.await(V8AwaitMode.RunNoWait)
            }
            if (eventLoopPumpActive && !disposed.get() && nodeRuntime != null) {
                handler.postDelayed(this, EVENT_LOOP_PUMP_MILLIS)
            }
        }
    }
    private var runtimeModule: V8Module? = null
    private var progressCallback: V8ValueFunction? = null
    private var pluginModuleLoader: V8ValueFunction? = null
    private val pluginModules = mutableListOf<V8Module>()
    private var runtimeRoot: File? = null
    private var dataRoot: File? = null
    private data class TransferSession(
        val target: File,
        val temporary: File,
        val expectedBytes: Long,
        val expectedSha256: String,
        var receivedBytes: Long = 0,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
    )
    private val transferSessions = mutableMapOf<String, TransferSession>()
    private data class ExportSession(val file: File, var offset: Long = 0)
    private val exportSessions = mutableMapOf<String, ExportSession>()

    fun invoke(
        method: String,
        params: Map<String, Any?>,
        deadlineUnixMs: Long,
        callback: (AndroidRuntimeError?, String?) -> Unit,
    ) {
        if (disposed.get()) {
            callback(AndroidRuntimeError("runtime_unavailable", "Android Runtime is closed."), null)
            return
        }
        handler.post {
            var phase = "starting"
            try {
                Log.i(TAG, "android_runtime_invoke_start")
                ensureStarted()
                phase = "invoking"
                val paramsJson = JSONObject(params).toString()
                val script = "globalThis.__mgreadInvokeJson(${JSONObject.quote(method)}," +
                    "${JSONObject.quote(paramsJson)},$deadlineUnixMs)"
                val result = awaitString(script)
                if (result.isBlank() || result == "undefined" || result == "null") {
                    callback(
                        AndroidRuntimeError(
                            "runtime_no_response",
                            "Android Runtime did not return a capability result.",
                        ),
                        null,
                    )
                    return@post
                }
                Log.i(TAG, "android_runtime_invoke_complete bytes=${result.length}")
                callback(null, result)
            } catch (_: Throwable) {
                runCatching { stopRuntime() }
                val code = if (phase == "starting") {
                    "runtime_start_failed"
                } else {
                    "runtime_invocation_failed"
                }
                Log.e(TAG, "android_runtime_invoke_failed code=$code")
                callback(
                    AndroidRuntimeError(
                        code,
                        "Android Runtime could not complete the capability call.",
                    ),
                    null,
                )
            }
        }
    }

    fun importLocalPlugin(
        sourcePath: String,
        callback: (AndroidRuntimeError?) -> Unit,
    ) {
        if (disposed.get()) {
            callback(AndroidRuntimeError("runtime_unavailable", "Android Runtime is closed."))
            return
        }
        handler.post {
            var temporary: File? = null
            var phase = "validate"
            try {
                val sourceName = selectedFileName(sourcePath)
                check(
                    !isContentUri(sourcePath) ||
                        sourceName.endsWith(".mgplugin", ignoreCase = true),
                ) {
                    "file_name_invalid"
                }
                val inbox = File(context.filesDir, "mgread-runtime/import-inbox").apply {
                    mkdirs()
                }
                val target = File(
                    inbox,
                    "import-${System.currentTimeMillis()}.mgplugin",
                )
                val temporaryFile = File(target.path + ".part")
                temporary = temporaryFile
                phase = "read"
                val sourceSize = selectedFileSize(sourcePath)
                onProgress(AndroidRuntimeProgress(0, "plugin_copying", sourceSize))
                copySelectedFile(sourcePath, temporaryFile) { copiedBytes ->
                    onProgress(AndroidRuntimeProgress(copiedBytes, "plugin_copying", sourceSize))
                }
                onProgress(AndroidRuntimeProgress(sourceSize, "plugin_copied", sourceSize))
                check(temporaryFile.renameTo(target)) { "disk_full" }
                phase = "runtime_start"
                onProgress(AndroidRuntimeProgress(0, "plugin_installing", 0))
                restartRuntime()
                ensureStarted()
                callback(null)
            } catch (error: Throwable) {
                temporary?.delete()
                runCatching { stopRuntime() }
                val code = when {
                    error.message == "file_name_invalid" -> "file_name_invalid"
                    error.message == "file_unavailable" -> "file_unavailable"
                    error.message == "file_unreadable" -> "file_unreadable"
                    error.message == "file_too_large" -> "file_too_large"
                    error.message == "invalid_request" -> "invalid_request"
                    error.message == "disk_full" -> "disk_full"
                    phase == "read" -> "file_read_failed"
                    phase == "runtime_start" -> "plugin_install_failed"
                    else -> "internal"
                }
                callback(
                    AndroidRuntimeError(
                        code,
                        "Android Runtime could not import the selected plugin.",
                    ),
                )
            }
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

    fun beginPluginTransfer(
        pluginId: String,
        version: String,
        expectedBytes: Long,
        expectedSha256: String,
        callback: (AndroidRuntimeError?, String?) -> Unit,
    ) {
        if (disposed.get()) {
            callback(AndroidRuntimeError("runtime_unavailable", "Android Runtime is closed."), null)
            return
        }
        handler.post {
            try {
                check(pluginId.matches(Regex("[a-z0-9][a-z0-9.-]{0,127}"))) { "invalid_request" }
                check(version.matches(Regex("\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?"))) { "invalid_request" }
                check(expectedBytes in 1..MAX_IMPORT_BYTES) { "file_too_large" }
                check(expectedSha256.matches(Regex("[a-f0-9]{64}"))) { "invalid_request" }
                check(transferSessions.size < MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
                val inbox = File(context.filesDir, "mgread-runtime/import-inbox").apply { mkdirs() }
                val id = UUID.randomUUID().toString().replace("-", "")
                val target = File(inbox, "transfer-$pluginId-$version-$id.mgplugin")
                val temporary = File(target.path + ".part")
                transferSessions[id] = TransferSession(target, temporary, expectedBytes, expectedSha256)
                callback(null, id)
            } catch (error: Throwable) {
                callback(AndroidRuntimeError(
                    if (error.message == "file_too_large") "plugin_transfer_archive_too_large" else "invalid_request",
                    "Android Runtime could not begin plugin transfer.",
                ), null)
            }
        }
    }

    fun beginPluginTransferExport(
        pluginId: String,
        version: String,
        callback: (AndroidRuntimeError?, Map<String, Any?>?) -> Unit,
    ) {
        handler.post {
            try {
                ensureStarted()
                check(pluginId.matches(Regex("[a-z0-9][a-z0-9.-]{0,127}"))) { "invalid_request" }
                check(version.matches(Regex("\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?"))) { "invalid_request" }
                val file = File(dataRoot ?: error("runtime_unavailable"), "plugin-archives/$pluginId/$version.mgplugin")
                check(file.isFile) { "plugin_transfer_archive_missing" }
                check(file.length() in 1..MAX_IMPORT_BYTES) { "plugin_transfer_archive_too_large" }
                val digest = MessageDigest.getInstance("SHA-256")
                file.inputStream().use { input ->
                    val buffer = ByteArray(TRANSFER_CHUNK_BYTES)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        digest.update(buffer, 0, read)
                    }
                }
                val id = UUID.randomUUID().toString().replace("-", "")
                exportSessions[id] = ExportSession(file)
                callback(null, mapOf("id" to id, "bytes" to file.length(), "sha256" to digest.digest().joinToString("") { byte -> "%02x".format(byte) }))
            } catch (error: Throwable) {
                callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not export the plugin archive."), null)
            }
        }
    }

    fun readPluginTransferExportChunk(
        id: String,
        callback: (AndroidRuntimeError?, ByteArray?) -> Unit,
    ) {
        handler.post {
            try {
                val session = exportSessions[id] ?: error("invalid_request")
                val remaining = session.file.length() - session.offset
                if (remaining <= 0) {
                    exportSessions.remove(id)
                    callback(null, ByteArray(0))
                    return@post
                }
                val count = minOf(remaining, TRANSFER_CHUNK_BYTES.toLong()).toInt()
                val output = ByteArray(count)
                session.file.inputStream().use { input ->
                    check(input.skip(session.offset) == session.offset) { "plugin_transfer_archive_missing" }
                    var read = 0
                    while (read < count) {
                        val next = input.read(output, read, count - read)
                        if (next < 0) break
                        read += next
                    }
                    check(read == count) { "plugin_transfer_archive_missing" }
                }
                session.offset += count
                callback(null, output)
            } catch (error: Throwable) {
                exportSessions.remove(id)
                callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not read the plugin archive."), null)
            }
        }
    }

    fun cancelPluginTransferExport(id: String) {
        handler.post { exportSessions.remove(id) }
    }

    fun writePluginTransferChunk(
        id: String,
        chunk: ByteArray,
        callback: (AndroidRuntimeError?) -> Unit,
    ) {
        handler.post {
            val session = transferSessions[id]
            if (session == null) {
                callback(AndroidRuntimeError("invalid_request", "Android plugin transfer session is unavailable."))
                return@post
            }
            try {
                check(chunk.size <= TRANSFER_CHUNK_BYTES) { "invalid_request" }
                check(session.receivedBytes + chunk.size <= session.expectedBytes) { "plugin_transfer_size_mismatch" }
                session.temporary.parentFile?.mkdirs()
                FileOutputStream(session.temporary, true).use { output -> output.write(chunk) }
                session.digest.update(chunk)
                session.receivedBytes += chunk.size
                callback(null)
            } catch (error: Throwable) {
                callback(AndroidRuntimeError(
                    if (error.message == "plugin_transfer_size_mismatch") "plugin_transfer_size_mismatch" else "disk_full",
                    "Android Runtime could not accept the plugin transfer chunk.",
                ))
            }
        }
    }

    fun finishPluginTransferBatch(
        ids: List<String>,
        callback: (AndroidRuntimeError?) -> Unit,
    ) {
        handler.post {
            try {
                check(ids.isNotEmpty() && ids.size <= MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
                ids.forEach { id ->
                    val session = transferSessions[id] ?: error("invalid_request")
                    check(session.receivedBytes == session.expectedBytes) { "plugin_transfer_size_mismatch" }
                    val actual = session.digest.digest().joinToString("") { byte -> "%02x".format(byte) }
                    check(actual == session.expectedSha256) { "plugin_transfer_checksum_mismatch" }
                    check(session.temporary.renameTo(session.target)) { "disk_full" }
                }
                ids.forEach { transferSessions.remove(it) }
                restartRuntime()
                ensureStarted()
                callback(null)
            } catch (error: Throwable) {
                ids.forEach { id -> transferSessions.remove(id)?.temporary?.delete() }
                runCatching { stopRuntime() }
                val code = when (error.message) {
                    "plugin_transfer_size_mismatch" -> "plugin_transfer_size_mismatch"
                    "plugin_transfer_checksum_mismatch" -> "plugin_transfer_checksum_mismatch"
                    "transfer_batch_too_large" -> "plugin_transfer_batch_too_large"
                    "disk_full" -> "disk_full"
                    else -> "plugin_transfer_failed"
                }
                callback(AndroidRuntimeError(code, "Android Runtime could not finalize plugin transfer."))
            }
        }
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        Log.i(TAG, "android_runtime_dispose_start")
        val latch = CountDownLatch(1)
        handler.post {
            try {
                stopRuntime()
                Log.i(TAG, "android_runtime_dispose_complete")
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
        thread.quitSafely()
    }

    private fun restartRuntime() {
        if (nodeRuntime == null) return
        stopRuntime()
        Log.i(TAG, "android_runtime_restarted_for_plugin_import")
    }

    private fun stopRuntime() {
        eventLoopPumpActive = false
        handler.removeCallbacks(eventLoopPump)
        nodeRuntime?.let {
            runCatching {
                awaitString("globalThis.__mgreadStopJson()")
            }
            it.setStopping(true)
            progressCallback?.close()
            progressCallback = null
            pluginModuleLoader?.close()
            pluginModuleLoader = null
            pluginModules.forEach { module -> runCatching { module.close() } }
            pluginModules.clear()
            runtimeModule?.close()
            runtimeModule = null
            it.close()
        }
        nodeRuntime = null
    }

    private fun ensureStarted() {
        if (nodeRuntime != null) return
        Log.i(TAG, "android_runtime_start")
        val root = File(context.filesDir, "mgread-runtime/android").apply { mkdirs() }
        AndroidRuntimeAssetExtractor(context, assetRoot, onProgress).ensure(root)
        val dist = File(root, "dist/desktop-runtime.js")
        check(dist.isFile) { "Android Runtime assets are missing." }
        Log.i(TAG, "android_runtime_node_create_start")
        onProgress(AndroidRuntimeProgress(0, "node_starting", 0))
        val runtime = V8Host.getNodeInstance().createV8Runtime<NodeRuntime>()
        Log.i(TAG, "android_runtime_node_create_complete")
        installProgressCallback(runtime)
        runtime.setV8ModuleResolver(AndroidModuleResolver(root))
        Log.i(TAG, "android_runtime_module_resolver_ready")
        nodeRuntime = runtime
        runtimeRoot = root
        val dataRoot = File(context.filesDir, "mgread-runtime/data").apply { mkdirs() }
        this.dataRoot = dataRoot
        val pluginImportInbox = File(
            context.filesDir,
            "mgread-runtime/import-inbox",
        ).apply { mkdirs() }
        installPluginModuleLoader(runtime, dataRoot)
        check(awaitString("Promise.resolve('android-runtime-probe')") == "android-runtime-probe")
        Log.i(TAG, "android_runtime_promise_probe_complete")
        val module = try {
            runtime.getExecutor(dist.readText())
                .setResourceName(dist.path)
                .setModule(true)
                .compileV8Module()
                .also { check(it.instantiate()) }
        } catch (error: Throwable) {
            Log.e(TAG, "android_runtime_module_compile_failed type=${error::class.java.simpleName}")
            throw error
        }
        try {
            awaitCompletion(module.evaluate<V8Value>())
        } catch (error: Throwable) {
            Log.e(TAG, "android_runtime_module_evaluate_failed type=${error::class.java.simpleName}")
            throw error
        }
        runtime.getGlobalObject().set("__mgreadDesktopRuntime", module.namespace)
        runtimeModule = module
        Log.i(TAG, "android_runtime_module_complete")
        // Android uses Javet's V8 resolver rather than Node's desktop module
        // loader. Keep it active so installed plugin files and dependencies
        // are compiled through AndroidModuleResolver in this same VM.
        Log.i(TAG, "android_runtime_plugin_module_loader_ready")
        val bootstrap = """
            (async () => {
              const { DesktopRuntime } = globalThis.__mgreadDesktopRuntime;
              const core = new DesktopRuntime({
                dataRoot: ${JSONObject.quote(dataRoot.path)},
                pluginImportInboxRoot: ${JSONObject.quote(pluginImportInbox.path)},
                embedded: true,
                debugHttpAllowed: ${isDebuggableBuild()},
                onProgress: (progress) => {
                  try {
                    globalThis.__mgreadReportProgress(JSON.stringify(progress));
                  } catch (_) {
                    // Progress is observational and must not change Runtime results.
                  }
                },
              });
              await core.start();
              const hello = await core.invokeEmbedded('runtime.hello', {});
              if (!hello.ok) throw new Error('runtime_hello_failed');
              globalThis.__mgreadCore = core;
              globalThis.__mgreadInvokeJson = async (method, paramsJson, deadline) => {
                try {
                  return JSON.stringify(await core.invokeEmbedded(method, JSON.parse(paramsJson), deadline));
                } catch (_) {
                  return JSON.stringify({ ok: false, error: { code: 'internal', message: 'Android Runtime invocation failed.' } });
                }
              };
              globalThis.__mgreadStopJson = async () => {
                await core.stop();
                return JSON.stringify({ ok: true });
              };
              return JSON.stringify({ ok: true });
            })()
        """.trimIndent()
        Log.i(TAG, "android_runtime_bootstrap_start")
        awaitString(bootstrap)
        eventLoopPumpActive = true
        handler.post(eventLoopPump)
        Log.i(TAG, "android_runtime_bootstrap_complete")
        Log.i(TAG, "android_runtime_ready")
        onProgress(AndroidRuntimeProgress(1, "ready", 1))
    }

    private fun awaitString(script: String): String {
        val runtime = nodeRuntime ?: throw IllegalStateException("Node Runtime is not started.")
        val value = runtime.getExecutor(script).execute<V8Value>()
        if (value !is V8ValuePromise) return value.toString()
        value.use { promise ->
            while (promise.isPending) {
                // A Runtime HTTP listener is intentionally persistent. Never
                // drain until no tasks remain: advance one non-blocking turn
                // and leave the HandlerThread free for its next command.
                runtime.await(V8AwaitMode.RunNoWait)
                Thread.sleep(EVENT_LOOP_PUMP_MILLIS)
            }
            if (promise.isRejected) {
                throw IllegalStateException("Javet promise rejected.")
            }
            runtime.await(V8AwaitMode.RunNoWait)
            promise.getResult<V8Value>().use { result ->
                return result.toString()
            }
        }
    }

    /** Uses the host application flag so this library does not depend on generated BuildConfig. */
    private fun isDebuggableBuild(): Boolean =
        context.applicationInfo.flags and ApplicationInfo.FLAG_DEBUGGABLE != 0

    private fun installProgressCallback(runtime: NodeRuntime) {
        val callbackContext = JavetCallbackContext(
            "__mgreadReportProgress",
            JavetCallbackType.DirectCallNoThisAndNoResult,
            object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                override fun call(vararg values: V8Value) {
                    val raw = values.firstOrNull()?.toString() ?: return
                    runCatching {
                        val event = JSONObject(raw)
                        val stage = event.optString("stage")
                        val completed = event.optLong("completedBytes", -1L)
                        val total = event.optLong("totalBytes", -1L)
                        val detail = event.optString("detail").takeIf { it.isNotEmpty() }
                        if (stage.isEmpty() || completed < 0L || total < 0L) return@runCatching
                        onProgress(AndroidRuntimeProgress(completed, stage, total, detail))
                    }
                }
            },
        )
        val callback = runtime.createV8ValueFunction(callbackContext)
        runtime.getGlobalObject().set("__mgreadReportProgress", callback)
        progressCallback = callback
    }

    /** Compiles installed plugin ESM through the same Javet resolver as Core. */
    private fun installPluginModuleLoader(runtime: NodeRuntime, dataRoot: File) {
        val callbackContext = JavetCallbackContext(
            "__mgreadLoadPluginModule",
            JavetCallbackType.DirectCallNoThisAndResult,
            object : IJavetDirectCallable.NoThisAndResult<Exception> {
                override fun call(vararg values: V8Value): V8Value {
                    val requestedPath = values.firstOrNull()?.toString()
                        ?: throw IllegalArgumentException("plugin_module_path_missing")
                    val dataRootPath = dataRoot.canonicalFile
                    val modulePath = File(requestedPath).canonicalFile
                    check(
                        modulePath.path == dataRootPath.path ||
                            modulePath.path.startsWith(dataRootPath.path + File.separator),
                    ) { "plugin_module_path_invalid" }
                    check(modulePath.isFile) { "plugin_module_missing" }
                    val module = runtime.getExecutor(modulePath)
                        .setResourceName(modulePath.path)
                        .setModule(true)
                        .compileV8Module()
                    try {
                        check(module.instantiate()) { "plugin_module_instantiate_failed" }
                        awaitCompletion(module.evaluate<V8Value>())
                        pluginModules += module
                        return module.namespace
                    } catch (error: Throwable) {
                        Log.e(TAG, "android_runtime_plugin_module_load_failed type=${error::class.java.simpleName}")
                        runCatching { module.close() }
                        throw error
                    }
                }
            },
        )
        pluginModuleLoader = runtime.createV8ValueFunction(callbackContext)
        runtime.getGlobalObject().set("__mgreadLoadPluginModule", pluginModuleLoader)
    }

    private fun awaitCompletion(value: V8Value) {
        if (value !is V8ValuePromise) {
            value.close()
            return
        }
        value.use { promise ->
            while (promise.isPending) {
                nodeRuntime?.await(V8AwaitMode.RunNoWait)
                Thread.sleep(EVENT_LOOP_PUMP_MILLIS)
            }
            if (promise.isRejected) {
                throw IllegalStateException("Javet module evaluation rejected.")
            }
            promise.getResult<V8Value>().use { }
        }
    }

    private companion object {
        const val EVENT_LOOP_PUMP_MILLIS = 10L
        const val MAX_IMPORT_BYTES = 32L * 1024L * 1024L
        const val MAX_TRANSFER_BATCH = 32
        const val TRANSFER_CHUNK_BYTES = 64 * 1024
        const val PROGRESS_REPORT_BYTES = 64L * 1024L
        const val TAG = "MgReadAndroidRuntime"
    }
}
