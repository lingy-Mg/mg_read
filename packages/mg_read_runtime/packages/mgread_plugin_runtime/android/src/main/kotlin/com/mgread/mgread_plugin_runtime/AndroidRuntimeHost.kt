package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.content.res.AssetManager
import android.net.Uri
import android.provider.OpenableColumns
import android.util.Log
import com.caoccao.javet.enums.V8AwaitMode
import com.caoccao.javet.interop.V8Runtime
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.IV8ModuleResolver
import com.caoccao.javet.interop.callback.JavetBuiltInModuleResolver
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.V8Host
import com.caoccao.javet.interop.options.NodeRuntimeOptions
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.IV8Module
import com.caoccao.javet.values.reference.V8Module
import com.caoccao.javet.values.reference.V8ValueFunction
import com.caoccao.javet.values.reference.V8ValuePromise
import org.json.JSONObject
import java.io.File
import java.io.FileOutputStream
import java.net.URI
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
    private var runtimeModule: V8Module? = null
    private var progressCallback: V8ValueFunction? = null
    private var runtimeRoot: File? = null

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
        nodeRuntime?.let {
            runCatching {
                awaitString("globalThis.__mgreadStopJson()")
            }
            it.setStopping(true)
            progressCallback?.close()
            progressCallback = null
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
        ensureRuntimeAssets(root)
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
        val pluginImportInbox = File(
            context.filesDir,
            "mgread-runtime/import-inbox",
        ).apply { mkdirs() }
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
        // The Runtime Core was compiled through Javet's resolver. Its later
        // plugin import() calls must use Node's standard package loader so the
        // installed project's normal node_modules and package exports apply.
        (runtime.runtimeOptions as NodeRuntimeOptions).setBuiltInModuleResolution(true)
        Log.i(TAG, "android_runtime_plugin_module_loader_ready")
        val bootstrap = """
            (async () => {
              const { DesktopRuntime } = globalThis.__mgreadDesktopRuntime;
              const core = new DesktopRuntime({
                dataRoot: ${JSONObject.quote(dataRoot.path)},
                pluginImportInboxRoot: ${JSONObject.quote(pluginImportInbox.path)},
                embedded: true,
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
                // Node's module loader and loopback HTTP server need the
                // pending libuv tasks to drain; RunNoWait only executes the
                // current microtask checkpoint and can leave the promise
                // pending forever on Android.
                runtime.await(V8AwaitMode.RunTillNoMoreTasks)
                Thread.yield()
            }
            if (promise.isRejected) {
                throw IllegalStateException("Javet promise rejected.")
            }
            // A fulfilled top-level promise can enqueue the final Node module
            // continuation that publishes a cold-activated plugin. Drain that
            // Runtime-owned checkpoint before exposing readiness to Flutter.
            runtime.await(V8AwaitMode.RunTillNoMoreTasks)
            Thread.yield()
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

    private fun awaitCompletion(value: V8Value) {
        if (value !is V8ValuePromise) {
            value.close()
            return
        }
        value.use { promise ->
            while (promise.isPending) {
                nodeRuntime?.await(V8AwaitMode.RunTillNoMoreTasks)
                Thread.yield()
            }
            if (promise.isRejected) {
                throw IllegalStateException("Javet module evaluation rejected.")
            }
            promise.getResult<V8Value>().use { }
        }
    }

    private fun copyAssets(
        assetPath: String,
        target: File,
        progress: ((Long) -> Unit)? = null,
    ) {
        val manager: AssetManager = context.assets
        val children = manager.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            target.parentFile?.mkdirs()
            manager.open(assetPath).use { input ->
                FileOutputStream(target).use { output ->
                    val buffer = ByteArray(DEFAULT_BUFFER_SIZE)
                    while (true) {
                        val read = input.read(buffer)
                        if (read < 0) break
                        output.write(buffer, 0, read)
                        progress?.invoke(read.toLong())
                    }
                }
            }
            return
        }
        target.mkdirs()
        for (child in children) {
            copyAssets("$assetPath/$child", File(target, child), progress)
        }
    }

    /**
     * Keeps the immutable package Runtime separate from user-owned Runtime data.
     * A matching package version reuses the existing extracted files; a changed
     * version replaces only this asset mirror before Node starts.
     */
    private fun ensureRuntimeAssets(root: File) {
        val bundledVersion = context.assets.open("$assetRoot/runtime-version.txt")
            .bufferedReader()
            .use { it.readText().trim() }
        check(bundledVersion.isNotEmpty()) { "Android Runtime asset version is missing." }
        val marker = File(root, ".runtime-asset-version")
        if (marker.isFile && marker.readText().trim() == bundledVersion) {
            Log.i(TAG, "android_runtime_assets_reused")
            onProgress(AndroidRuntimeProgress(1, "assets_reused", 1))
            return
        }

        Log.i(TAG, "android_runtime_assets_replace_start")
        if (root.exists() && !root.deleteRecursively()) {
            throw IllegalStateException("Android Runtime asset directory cannot be replaced.")
        }
        check(root.mkdirs() || root.isDirectory) { "Android Runtime asset directory is unavailable." }
        val totalBytes = measureAssetBytes(assetRoot)
        var copiedBytes = 0L
        onProgress(AndroidRuntimeProgress(0, "assets_copying", totalBytes))
        copyAssets(assetRoot, root) { copied ->
            copiedBytes += copied
            onProgress(AndroidRuntimeProgress(copiedBytes, "assets_copying", totalBytes))
        }
        val temporaryMarker = File(root, ".runtime-asset-version.next")
        temporaryMarker.writeText("$bundledVersion\n")
        check(temporaryMarker.renameTo(marker)) { "Android Runtime asset version cannot be committed." }
        Log.i(TAG, "android_runtime_assets_replace_complete")
        onProgress(AndroidRuntimeProgress(totalBytes, "assets_copied", totalBytes))
    }

    private fun measureAssetBytes(assetPath: String): Long {
        val manager: AssetManager = context.assets
        val children = manager.list(assetPath) ?: emptyArray()
        if (children.isEmpty()) {
            return manager.open(assetPath).use { it.available().toLong() }
        }
        return children.sumOf { child -> measureAssetBytes("$assetPath/$child") }
    }

    /** Resolves the compiled Runtime's file ESM graph inside the extracted asset root. */
    private class AndroidModuleResolver(
        private val root: File,
    ) : IV8ModuleResolver {
        private val builtIn = JavetBuiltInModuleResolver()

        override fun resolve(
            runtime: V8Runtime,
            moduleName: String,
            referrer: IV8Module?,
        ): IV8Module? {
            if (moduleName.startsWith("node:")) {
                return builtIn.resolve(runtime, moduleName, referrer)
            }
            val referrerFile = referrer?.resourceName?.let(::File)
            val candidate = when {
                moduleName.startsWith("file:") -> File(URI(moduleName))
                moduleName.startsWith("/") -> File(moduleName)
                referrerFile != null -> File(referrerFile.parentFile, moduleName)
                else -> File(root, moduleName)
            }.canonicalFile
            if (!candidate.isFile) {
                Log.e(TAG, "android_runtime_module_resolve_missing")
                return null
            }
            return runtime.getExecutor(candidate.readText())
                .setResourceName(candidate.path)
                .setModule(true)
                .compileV8Module()
        }
    }

    private companion object {
        const val MAX_IMPORT_BYTES = 32L * 1024L * 1024L
        const val PROGRESS_REPORT_BYTES = 64L * 1024L
        const val TAG = "MgReadAndroidRuntime"
    }
}
