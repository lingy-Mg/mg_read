package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.content.res.AssetManager
import android.util.Log
import com.caoccao.javet.enums.V8AwaitMode
import com.caoccao.javet.interop.V8Runtime
import com.caoccao.javet.interop.callback.IV8ModuleResolver
import com.caoccao.javet.interop.callback.JavetBuiltInModuleResolver
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.V8Host
import com.caoccao.javet.interop.options.NodeRuntimeOptions
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.IV8Module
import com.caoccao.javet.values.reference.V8Module
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
            try {
                Log.i(TAG, "android_runtime_invoke_start")
                ensureStarted()
                val paramsJson = JSONObject(params).toString()
                val script = "globalThis.__mgreadInvokeJson(${JSONObject.quote(method)}," +
                    "${JSONObject.quote(paramsJson)},$deadlineUnixMs)"
                val result = awaitString(script)
                Log.i(TAG, "android_runtime_invoke_complete bytes=${result.length}")
                callback(null, result)
            } catch (_: Throwable) {
                Log.e(TAG, "android_runtime_invoke_failed code=runtime_start_failed")
                callback(
                    AndroidRuntimeError(
                        "runtime_start_failed",
                        "Android Runtime could not complete the capability call.",
                    ),
                    null,
                )
            }
        }
    }

    fun dispose() {
        if (!disposed.compareAndSet(false, true)) return
        Log.i(TAG, "android_runtime_dispose_start")
        val latch = CountDownLatch(1)
        handler.post {
            try {
                nodeRuntime?.let {
                    runCatching {
                        awaitString("globalThis.__mgreadStopJson()")
                    }
                    it.setStopping(true)
                    runtimeModule?.close()
                    runtimeModule = null
                    it.close()
                }
                nodeRuntime = null
                Log.i(TAG, "android_runtime_dispose_complete")
            } finally {
                latch.countDown()
            }
        }
        latch.await(5, TimeUnit.SECONDS)
        thread.quitSafely()
    }

    private fun ensureStarted() {
        if (nodeRuntime != null) return
        Log.i(TAG, "android_runtime_start")
        val root = File(context.filesDir, "mgread-runtime/android").apply { mkdirs() }
        ensureRuntimeAssets(root)
        val dist = File(root, "dist/desktop-runtime.js")
        val plugins = File(root, "default-plugins")
        check(dist.isFile && plugins.isDirectory) { "Android Runtime assets are missing." }
        Log.i(TAG, "android_runtime_node_create_start")
        onProgress(AndroidRuntimeProgress(0, "node_starting", 0))
        val runtime = V8Host.getNodeInstance().createV8Runtime<NodeRuntime>()
        Log.i(TAG, "android_runtime_node_create_complete")
        runtime.setV8ModuleResolver(AndroidModuleResolver(root))
        Log.i(TAG, "android_runtime_module_resolver_ready")
        nodeRuntime = runtime
        runtimeRoot = root
        val dataRoot = File(context.filesDir, "mgread-runtime/data").apply { mkdirs() }
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
                bundledPluginRoot: ${JSONObject.quote(plugins.path)},
                embedded: true,
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
        const val TAG = "MgReadAndroidRuntime"
    }
}
