/** Javet VM, asynchronous Core lifecycle and callback-based capability ownership.
 * Only the event-loop thread touches V8. Calls, browser replies, cancellation
 * and one-shot deadlines wake its libuv pipe; no sleep or periodic Java pump.
 * Restart invalidates outstanding calls before replacing the Core in the same VM.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import android.util.Log
import com.caoccao.javet.enums.V8AwaitMode
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.V8Host
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8Module
import com.caoccao.javet.values.reference.V8ValueFunction
import java.io.File
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.ScheduledThreadPoolExecutor
import java.util.concurrent.ScheduledFuture
import java.util.concurrent.TimeUnit
import java.util.concurrent.Semaphore
import java.util.concurrent.atomic.AtomicBoolean
import org.json.JSONObject

internal class AndroidJavetEngine(
    private val context: Context,
    private val assetRoot: String,
    private val browserHost: AndroidBrowserSessionHost,
    private val onProgress: (AndroidRuntimeProgress) -> Unit,
    private val onClosed: () -> Unit,
) {
    private enum class State { STOPPED, STARTING, READY, RESTARTING, FAILED, CLOSING, CLOSED }
    private class Call(val id: String, val callback: (AndroidRuntimeError?, String?) -> Unit) {
        val cancelled = AtomicBoolean(false)
        val completed = AtomicBoolean(false)
        var deadline: ScheduledFuture<*>? = null
        var observation: String? = null
        var awaitingReady: ((AndroidRuntimeError?) -> Unit)? = null
    }
    private val closing = AtomicBoolean(false)
    private val loop = AndroidRuntimeEventLoop { failEngine() }
    private val timers = ScheduledThreadPoolExecutor(1) { task ->
        Thread(task, "mgread-node-deadlines").apply { isDaemon = true }
    }.apply { removeOnCancelPolicy = true; setExecuteExistingDelayedTasksAfterShutdownPolicy(false) }
    private val calls = ConcurrentHashMap<String, Call>()
    private val capacity = Semaphore(256)
    private var state = State.STOPPED
    private val ready = mutableListOf<(AndroidRuntimeError?) -> Unit>()
    private var runtime: NodeRuntime? = null
    private var createdVm = false
    private var callbacks: AndroidJavetCallbacks? = null
    private var wakeup: AndroidJavetWakeup? = null
    private var module: V8Module? = null
    private var browserBridge: AndroidBrowserJavetBridge? = null
    private var progress: V8ValueFunction? = null
    private var loader: V8ValueFunction? = null
    private val pluginModules = mutableListOf<V8Module>()
    private var shutdownDeadline: ScheduledFuture<*>? = null
    private var lifecycleDeadline: ScheduledFuture<*>? = null
    private var lifecycleGeneration = 0L
    var dataRoot: File? = null
        private set

    fun submit(onError: (AndroidRuntimeError) -> Unit, action: () -> Unit) {
        if (closing.get() || !loop.post {
            if (closing.get()) onError(unavailable()) else action()
        }) onError(unavailable())
    }

    fun withCore(callback: (AndroidRuntimeError?) -> Unit) = submit({ callback(it) }) { ensureReady(callback) }

    fun invoke(id: String, method: String, params: Map<String, Any?>, deadlineUnixMs: Long,
               callback: (AndroidRuntimeError?, String?) -> Unit) {
        val call = Call(id, callback)
        if (!capacity.tryAcquire()) {
            callback(AndroidRuntimeError("overloaded", "Android Runtime has too many pending invocations."), null)
            return
        }
        if (calls.putIfAbsent(id, call) != null) {
            capacity.release()
            callback(AndroidRuntimeError("invalid_request", "Android Runtime request id is already active."), null)
            return
        }
        if (closing.get()) { finish(call, unavailable(), null); return }
        try {
            call.deadline = timers.schedule({
                call.cancelled.set(true)
                loop.post { cancelInCore(id); finish(call, AndroidRuntimeError("timeout", "Android Runtime invocation timed out."), null) }
            }, (deadlineUnixMs - System.currentTimeMillis()).coerceAtLeast(0), TimeUnit.MILLISECONDS)
        } catch (_: Throwable) { finish(call, unavailable(), null); return }
        submit({ finish(call, it, null) }) {
            val onReady: (AndroidRuntimeError?) -> Unit = onReady@ { error ->
                if (calls[id] !== call) return@onReady
                if (error != null) { finish(call, error, null); return@onReady }
                if (call.cancelled.get()) { finish(call, cancelled(), null); return@onReady }
                val vm = runtime ?: return@onReady finish(call, unavailable(), null)
                try {
                    call.observation = observe(vm.getGlobalObject().invoke<V8Value>("__mgreadInvokeJson", id, method, JSONObject(params).toString(), deadlineUnixMs.toDouble())) { ok, result ->
                        if (!ok) finish(call, invocationFailed(), null)
                        else if (result.isNullOrBlank() || result == "undefined" || result == "null")
                            finish(call, AndroidRuntimeError("runtime_no_response", "Android Runtime did not return a capability result."), null)
                        else finish(call, null, result)
                    }
                } catch (_: Throwable) { finish(call, invocationFailed(), null) }
            }
            call.awaitingReady = onReady
            ensureReady(onReady)
        }
    }

    fun cancel(id: String) {
        val call = calls[id] ?: return
        call.cancelled.set(true)
        loop.post { cancelInCore(id); finish(call, cancelled(), null) }
    }

    private fun finish(call: Call, error: AndroidRuntimeError?, result: String?) {
        if (!call.completed.compareAndSet(false, true)) return
        calls.remove(call.id, call)
        capacity.release()
        call.deadline?.cancel(false)
        callbacks?.forget(call.observation)
        call.awaitingReady?.let { ready.remove(it) }
        runCatching { call.callback(error, result) }
    }

    private fun cancelInCore(id: String) {
        runCatching { runtime?.getGlobalObject()?.invokeVoid("__mgreadCancelJson", id) }
    }

    private fun abortCalls(error: AndroidRuntimeError) {
        calls.values.toList().forEach { call ->
            call.cancelled.set(true)
            cancelInCore(call.id)
            finish(call, error, null)
        }
    }

    private fun ensureReady(callback: (AndroidRuntimeError?) -> Unit) {
        if (closing.get()) { callback(unavailable()); return }
        if (state == State.READY) { callback(null); return }
        ready += callback
        if (state == State.STARTING || state == State.RESTARTING) return
        state = State.STARTING
        armLifecycleDeadline()
        if (runtime != null && module != null) { replaceCore(); return }
        if (createdVm) { completeReady(startFailed()); return }
        try { startVm() } catch (_: Throwable) { completeReady(startFailed()) }
    }

    private fun completeReady(error: AndroidRuntimeError?) {
        if (closing.get()) return
        lifecycleDeadline?.cancel(false)
        lifecycleGeneration++
        state = if (error == null) State.READY else State.FAILED
        val listeners = ready.toList()
        ready.clear()
        listeners.forEach { listener -> loop.post {
            if (error == null && state != State.READY) ensureReady(listener) else listener(error)
        } }
    }

    private fun startVm() {
        val root = File(context.filesDir, "mgread-runtime/android").apply { mkdirs() }
        AndroidRuntimeAssetExtractor(context, assetRoot, onProgress).ensure(root)
        val entry = File(root, "dist/desktop-runtime.js")
        check(entry.isFile)
        onProgress(AndroidRuntimeProgress(0, "node_starting", 0))
        val vm = V8Host.getNodeInstance().createV8Runtime<NodeRuntime>()
        createdVm = true
        runtime = vm
        vm.setV8ModuleResolver(AndroidModuleResolver(root))
        callbacks = AndroidJavetCallbacks(vm, loop::post)
        wakeup = AndroidJavetWakeup { loop.post { failEngine() } }.also { it.install(vm) }
        loop.setDriver({ mayBlock ->
            vm.await(V8AwaitMode.RunNoWait)
            if (mayBlock && !loop.hasCommands()) vm.await(V8AwaitMode.RunOnce)
        }, { wakeup?.signal() })
        installProgress(vm)
        browserBridge = AndroidBrowserJavetBridge(browserHost, loop::post).also { it.install(vm) }
        val data = File(context.filesDir, "mgread-runtime/data").apply { mkdirs() }
        dataRoot = data
        val inbox = File(data, "import-inbox").apply { mkdirs() }
        installLoader(vm, data)
        val compiled = vm.getExecutor(androidModuleSource(entry)).setResourceName(entry.path).setModule(true).compileV8Module()
        module = compiled
        check(compiled.instantiate())
        observe(compiled.evaluate<V8Value>()) { ok, _ ->
            if (closing.get()) return@observe
            if (!ok) { completeReady(startFailed()); return@observe }
            try {
                compiled.namespace.use { vm.getGlobalObject().set("__mgreadDesktopRuntime", it) }
                observe(vm.getExecutor(androidJavetCoreBootstrap(data, inbox)).execute<V8Value>()) { started, _ ->
                    if (started) onProgress(AndroidRuntimeProgress(1, "ready", 1))
                    completeReady(if (started) null else startFailed())
                }
            } catch (_: Throwable) { completeReady(startFailed()) }
        }
    }

    fun restartCore(callback: (AndroidRuntimeError?) -> Unit) {
        if (closing.get()) { callback(unavailable()); return }
        if (state == State.STARTING || state == State.RESTARTING) {
            ready += { error -> if (error != null) callback(error) else restartCore(callback) }
            return
        }
        if (runtime == null) { ensureReady(callback); return }
        ready += callback
        state = State.RESTARTING
        armLifecycleDeadline()
        replaceCore()
    }

    private fun replaceCore() {
        abortCalls(AndroidRuntimeError("runtime_unavailable", "Android Runtime is restarting its Core."))
        callFunction("__mgreadStopJson") { stopped, _ ->
            if (closing.get()) return@callFunction
            if (!stopped) { completeReady(startFailed()); return@callFunction }
            clearModules()
            callFunction("__mgreadStartCoreJson") { ok, _ -> completeReady(if (ok) null else startFailed()) }
        }
    }

    fun recover(callback: () -> Unit) {
        if (runtime == null || closing.get()) { callback(); return }
        restartCore { callback() }
    }

    private fun armLifecycleDeadline() {
        lifecycleDeadline?.cancel(false)
        val generation = ++lifecycleGeneration
        lifecycleDeadline = timers.schedule({ loop.post {
            if (generation == lifecycleGeneration && (state == State.STARTING || state == State.RESTARTING)) failEngine()
        } }, 30, TimeUnit.SECONDS)
    }

    private fun observe(value: V8Value, callback: (Boolean, String?) -> Unit): String {
        val observer = callbacks ?: error("runtime_unavailable")
        return observer.observe(value, callback)
    }

    private fun callFunction(name: String, callback: (Boolean, String?) -> Unit) {
        val vm = runtime
        if (vm == null) { callback(false, null); return }
        try { observe(vm.getGlobalObject().invoke<V8Value>(name, *emptyArray<Any>()), callback) }
        catch (_: Throwable) { callback(false, null) }
    }

    private fun installLoader(vm: NodeRuntime, root: File) {
        val context = JavetCallbackContext("__mgreadCompilePluginModule", JavetCallbackType.DirectCallNoThisAndResult,
            object : IJavetDirectCallable.NoThisAndResult<Exception> {
                override fun call(vararg values: V8Value): V8Value {
                    val path = File(values.firstOrNull()?.toString() ?: error("plugin_module_path_missing")).canonicalFile
                    check(path.path.startsWith(root.canonicalPath + File.separator) && path.isFile)
                    val compiled = vm.getExecutor(androidModuleSource(path)).setResourceName(path.path).setModule(true).compileV8Module()
                    try {
                        check(compiled.instantiate())
                        val result = vm.createV8ValueObject()
                        compiled.namespace.use { result.set("namespace", it) }
                        compiled.evaluate<V8Value>().use { result.set("evaluation", it) }
                        pluginModules += compiled
                        return result
                    } catch (_: Throwable) {
                        compiled.close()
                        throw AndroidRuntimeError("runtime_module_compile_failed", "Android could not load a plugin module.")
                    }
                }
            })
        loader = vm.createV8ValueFunction(context)
        vm.getGlobalObject().set("__mgreadCompilePluginModule", loader)
        vm.getExecutor("""
            globalThis.__mgreadLoadPluginModule = async path => {
              const loaded = globalThis.__mgreadCompilePluginModule(path);
              await loaded.evaluation;
              return loaded.namespace;
            };
        """.trimIndent()).executeVoid()
    }

    private fun installProgress(vm: NodeRuntime) {
        val context = JavetCallbackContext("__mgreadReportProgress", JavetCallbackType.DirectCallNoThisAndNoResult,
            object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                override fun call(vararg values: V8Value) {
                    runCatching {
                        val event = JSONObject(values.firstOrNull()?.toString() ?: return)
                        val stage = event.optString("stage")
                        val completed = event.optLong("completedBytes", -1)
                        val total = event.optLong("totalBytes", -1)
                        if (stage.isEmpty() || completed < 0 || total < 0) return
                        onProgress(AndroidRuntimeProgress(completed, stage, total, event.optString("detail").takeIf { it.isNotEmpty() },
                            event.optLong("durationMicros", -1).takeIf { it >= 0 }, event.optLong("itemCount", -1).takeIf { it >= 0 },
                            event.optString("catalogState").takeIf { it.isNotEmpty() }))
                    }
                }
            })
        progress = vm.createV8ValueFunction(context)
        vm.getGlobalObject().set("__mgreadReportProgress", progress)
    }

    fun dispose() {
        if (!closing.compareAndSet(false, true)) return
        loop.post {
            if (state == State.CLOSED) return@post
            state = State.CLOSING
            lifecycleDeadline?.cancel(false)
            abortCalls(unavailable())
            val listeners = ready.toList(); ready.clear(); listeners.forEach { it(unavailable()) }
            browserHost.dispose()
            shutdownDeadline = timers.schedule({ loop.post { closeVm() } }, 5, TimeUnit.SECONDS)
            callFunction("__mgreadStopJson") { _, _ -> closeVm() }
        }
    }

    private fun clearModules() {
        pluginModules.forEach { runCatching { it.close() } }
        pluginModules.clear()
    }

    private fun closeVm() {
        if (state == State.CLOSED) return
        state = State.CLOSED
        loop.setDriver(null)
        shutdownDeadline?.cancel(false)
        lifecycleDeadline?.cancel(false)
        runtime?.let { vm ->
            runCatching { wakeup?.closeNode(vm) }
            runCatching { callbacks?.close() }
            runCatching { browserBridge?.close() }
            clearModules()
            runCatching { loader?.close() }; runCatching { progress?.close() }; runCatching { module?.close() }
            runCatching { vm.setStopping(true); vm.close() }
        }
        runtime = null
        runCatching { wakeup?.close() }; wakeup = null
        runCatching { onClosed() }
        timers.shutdownNow()
        loop.shutdown()
    }

    private fun failEngine() {
        if (state == State.CLOSED) return
        closing.set(true)
        state = State.FAILED
        abortCalls(unavailable())
        val listeners = ready.toList(); ready.clear(); listeners.forEach { it(startFailed()) }
        Log.e("MgReadAndroidRuntime", "android_runtime_event_loop_failed")
        browserHost.dispose()
        closeVm()
    }

    private fun unavailable() = AndroidRuntimeError("runtime_unavailable", "Android Runtime is closed or restarting.")
    private fun cancelled() = AndroidRuntimeError("cancelled", "Android Runtime invocation was cancelled.")
    private fun startFailed() = AndroidRuntimeError("runtime_start_failed", "Android Runtime could not start its Core.")
    private fun invocationFailed() = AndroidRuntimeError("runtime_invocation_failed", "Android Runtime could not complete the capability call.")
}
