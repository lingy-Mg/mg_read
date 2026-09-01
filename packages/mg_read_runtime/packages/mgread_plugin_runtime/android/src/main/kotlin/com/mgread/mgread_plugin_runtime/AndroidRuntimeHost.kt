/**
 * Android Runtime host.
 *
 * Owns the single Javet NodeRuntime, its HandlerThread, and the bounded event-loop pump.
 * Flutter only receives typed capability results through the package bridge.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.app.Activity
import android.net.Uri
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
import java.io.FileOutputStream
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
    private var coreStarted = false
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
    private val browserSessionHost = AndroidBrowserSessionHost(context)
    private var browserJavetBridge: AndroidBrowserJavetBridge? = null
    private val pluginModules = mutableListOf<V8Module>()
    private var runtimeRoot: File? = null
    private var dataRoot: File? = null
    private val artifactTransfer = AndroidPluginArtifactTransfer(context)

    fun attachActivity(activity: Activity?) {
        browserSessionHost.attachActivity(activity)
    }

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
                recoverCoreAfterFailedActivation()
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
                val artifactFormat = artifactFormatForName(sourceName)
                    ?: error("file_name_invalid")
                val inbox = File(context.filesDir, "mgread-runtime/import-inbox").apply {
                    mkdirs()
                }
                val target = File(
                    inbox,
                    "import-${System.currentTimeMillis()}${artifactSuffix(artifactFormat)}",
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
                restartCore()
                callback(null)
            } catch (error: Throwable) {
                temporary?.delete()
                recoverCoreAfterFailedActivation()
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
        format: String,
        callback: (AndroidRuntimeError?, String?) -> Unit,
    ) {
        if (disposed.get()) {
            callback(AndroidRuntimeError("runtime_unavailable", "Android Runtime is closed."), null)
            return
        }
        handler.post {
            try {
                Log.i(TAG, "android_plugin_transfer_receive_started bytes=$expectedBytes")
                val id = artifactTransfer.beginImport(
                    pluginId = pluginId,
                    version = version,
                    expectedBytes = expectedBytes,
                    expectedSha256 = expectedSha256,
                    format = format,
                )
                callback(null, id)
            } catch (error: Throwable) {
                callback(AndroidRuntimeError(
                    if (error.message == "file_too_large") "plugin_transfer_artifact_too_large" else "invalid_request",
                    "Android Runtime could not begin plugin transfer.",
                ), null)
            }
        }
    }

    fun beginPluginTransferExport(
        pluginId: String,
        version: String,
        format: String,
        callback: (AndroidRuntimeError?, Map<String, Any?>?) -> Unit,
    ) {
        handler.post {
            try {
                ensureStarted()
                callback(
                    null,
                    artifactTransfer.beginExport(
                        dataRoot = dataRoot ?: error("runtime_unavailable"),
                        pluginId = pluginId,
                        version = version,
                        format = format,
                    ),
                )
            } catch (error: Throwable) {
                callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not export the plugin artifact."), null)
            }
        }
    }

    fun readPluginTransferExportChunk(
        id: String,
        callback: (AndroidRuntimeError?, ByteArray?) -> Unit,
    ) {
        handler.post {
            try {
                callback(null, artifactTransfer.readExportChunk(id))
            } catch (error: Throwable) {
                artifactTransfer.cancelExport(id)
                callback(AndroidRuntimeError(error.message ?: "invalid_request", "Android Runtime could not read the plugin artifact."), null)
            }
        }
    }

    fun cancelPluginTransferExport(id: String) {
        handler.post { artifactTransfer.cancelExport(id) }
    }

    fun writePluginTransferChunk(
        id: String,
        chunk: ByteArray,
        callback: (AndroidRuntimeError?) -> Unit,
    ) {
        handler.post {
            try {
                artifactTransfer.writeImportChunk(id, chunk)
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
                Log.i(TAG, "android_plugin_transfer_finalize_started")
                artifactTransfer.finishImportBatch(ids)
                Log.i(TAG, "android_plugin_transfer_artifacts_verified")
                restartCore()
                Log.i(TAG, "android_plugin_transfer_finalize_complete")
                callback(null)
            } catch (error: Throwable) {
                artifactTransfer.cancelImports(ids)
                recoverCoreAfterFailedActivation()
                val code = when (error.message) {
                    "plugin_transfer_size_mismatch" -> "plugin_transfer_size_mismatch"
                    "plugin_transfer_checksum_mismatch" -> "plugin_transfer_checksum_mismatch"
                    "transfer_batch_too_large" -> "plugin_transfer_batch_too_large"
                    "disk_full" -> "disk_full"
                    else -> "plugin_transfer_failed"
                }
                Log.e(TAG, "android_plugin_transfer_finalize_failed code=$code")
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
        browserSessionHost.dispose()
        thread.quitSafely()
    }

    /**
     * Cold-activates installed sources without tearing down Javet's sole Node VM.
     *
     * Javet owns native process state below [NodeRuntime]. Recreating that VM
     * immediately after a transfer can terminate the Android process on some
     * devices. A fresh DesktopRuntime Core still re-reads the inbox and builds
     * a new PluginManager, so pending immutable artifacts are never hot-loaded.
     */
    private fun restartCore() {
        if (nodeRuntime == null) {
            ensureStarted()
            return
        }
        eventLoopPumpActive = false
        handler.removeCallbacks(eventLoopPump)
        awaitString("globalThis.__mgreadStopJson()")
        coreStarted = false
        clearPluginModules()
        awaitString("globalThis.__mgreadStartCoreJson()")
        coreStarted = true
        eventLoopPumpActive = true
        handler.post(eventLoopPump)
        Log.i(TAG, "android_runtime_core_restarted_for_plugin_import")
    }

    /** Restores a usable Core after the inbox has discarded one bad artifact. */
    private fun recoverCoreAfterFailedActivation() {
        if (nodeRuntime == null) return
        eventLoopPumpActive = false
        handler.removeCallbacks(eventLoopPump)
        coreStarted = false
        runCatching { awaitString("globalThis.__mgreadStopJson()") }
        clearPluginModules()
        if (runCatching { awaitString("globalThis.__mgreadStartCoreJson()") }.isSuccess) {
            coreStarted = true
            Log.i(TAG, "android_runtime_core_recovered_after_plugin_import_failure")
        }
        eventLoopPumpActive = true
        handler.post(eventLoopPump)
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
            browserJavetBridge?.close()
            browserJavetBridge = null
            clearPluginModules()
            runtimeModule?.close()
            runtimeModule = null
            it.close()
        }
        nodeRuntime = null
        coreStarted = false
    }

    private fun ensureStarted() {
        if (nodeRuntime != null) {
            if (!coreStarted) restartCore()
            return
        }
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
        browserJavetBridge = AndroidBrowserJavetBridge(browserSessionHost).also {
            it.install(runtime)
        }
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
            runtime.getExecutor(androidModuleSource(dist))
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
        val browserProvider = androidBrowserProviderBootstrap()
        val bootstrap = """
            (async () => {
              const { DesktopRuntime, PluginBrowserSessionError } = globalThis.__mgreadDesktopRuntime;
              $browserProvider
              globalThis.__mgreadStartCoreJson = async () => {
                const core = new DesktopRuntime({
                  browserSession,
                  dataRoot: ${JSONObject.quote(dataRoot.path)},
                  pluginImportInboxRoot: ${JSONObject.quote(pluginImportInbox.path)},
                  embedded: true,
                  // The inspector is available in release builds too, but
                  // DesktopRuntime keeps its listener disabled by default
                  // until the user explicitly enables the Runtime setting.
                  debugHttpAllowed: true,
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
                return JSON.stringify({ ok: true });
              };
              globalThis.__mgreadInvokeJson = async (method, paramsJson, deadline) => {
                try {
                  return JSON.stringify(await globalThis.__mgreadCore.invokeEmbedded(method, JSON.parse(paramsJson), deadline));
                } catch (_) {
                  return JSON.stringify({ ok: false, error: { code: 'internal', message: 'Android Runtime invocation failed.' } });
                }
              };
              globalThis.__mgreadStopJson = async () => {
                const core = globalThis.__mgreadCore;
                if (core) await core.stop();
                globalThis.__mgreadCore = undefined;
                return JSON.stringify({ ok: true });
              };
              return globalThis.__mgreadStartCoreJson();
            })()
        """.trimIndent()
        Log.i(TAG, "android_runtime_bootstrap_start")
        awaitString(bootstrap)
        coreStarted = true
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
                    val module = runtime.getExecutor(androidModuleSource(modulePath))
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

    /** Releases modules loaded by the previous Core before cold activation. */
    private fun clearPluginModules() {
        pluginModules.forEach { module -> runCatching { module.close() } }
        pluginModules.clear()
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
        const val PROGRESS_REPORT_BYTES = 64L * 1024L
        const val TAG = "MgReadAndroidRuntime"
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
