/**
 * Main-process owner of the Android Node service binding and startup record.
 *
 * It extracts the immutable Core asset, binds one private remote service, and
 * forwards bounded lifecycle records to Flutter. It never sends capability
 * payloads through Binder; the Core's authenticated loopback protocol owns
 * those requests. A failed process remains failed until an explicit restart.
 */
package com.mgread.mgread_plugin_runtime

import android.content.ComponentName
import android.content.Context
import android.content.Intent
import android.content.ServiceConnection
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import org.json.JSONObject
import java.io.File
import java.util.concurrent.Executors

internal class AndroidNodeProcessController(
    private val context: Context,
    private val assetRoot: String,
    private val onProgress: (AndroidRuntimeProgress) -> Unit,
    private val onEvent: (Map<String, Any?>) -> Unit,
) {
    private val main = Handler(Looper.getMainLooper())
    private val extraction = Executors.newSingleThreadExecutor { runnable ->
        Thread(runnable, "mgread-node-assets").apply { isDaemon = true }
    }
    private val callbacks = mutableListOf<(AndroidRuntimeError?, String?) -> Unit>()
    private val receiver = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            if (message.data.getInt(AndroidNodeProcessIpc.KEY_GENERATION, -1) != startupGeneration) return
            when (message.what) {
                AndroidNodeProcessIpc.STDOUT -> line("node_stdout", message.data)
                AndroidNodeProcessIpc.STDERR -> line("node_stderr", message.data)
                AndroidNodeProcessIpc.EXIT -> failed("runtime_process_exited", message.data.getString(AndroidNodeProcessIpc.KEY_CODE))
                AndroidNodeProcessIpc.ERROR -> failed("runtime_start_failed", message.data.getString(AndroidNodeProcessIpc.KEY_CODE))
                else -> super.handleMessage(message)
            }
        }
    })
    private var connection: ServiceConnection? = null
    private var service: Messenger? = null
    private var ready: String? = null
    private var disposed = false
    private var terminalFailure = false
    private var binding = false
    private var restartPending = false
    private var startupGeneration = 0

    fun start(callback: (AndroidRuntimeError?, String?) -> Unit) {
        main.post {
            if (disposed || terminalFailure) {
                callback(AndroidRuntimeError("runtime_unavailable", "Android Node process is unavailable."), null)
                return@post
            }
            ready?.let { callback(null, it); return@post }
            callbacks += callback
            if (binding) return@post
            binding = true
            val generation = ++startupGeneration
            extraction.execute {
                val result = runCatching {
                    val root = File(context.filesDir, "mgread-runtime/android")
                    AndroidRuntimeAssetExtractor(context, assetRoot, onProgress).ensure(root)
                    check(File(root, "dist/cli.js").isFile) { "Runtime CLI asset is missing." }
                }
                main.post {
                    if (generation != startupGeneration || disposed) return@post
                    if (result.isFailure) {
                        failed("runtime_assets_unavailable", null)
                    } else {
                        bind(generation)
                    }
                }
            }
            main.postDelayed({
                if (generation == startupGeneration && ready == null && binding) {
                    failed("runtime_not_ready", null)
                }
            }, STARTUP_TIMEOUT_MILLIS)
        }
    }

    private fun bind(generation: Int) {
        val candidate = object : ServiceConnection {
            override fun onServiceConnected(name: ComponentName?, binder: IBinder?) {
                if (generation != startupGeneration || disposed) return
                if (binder == null) {
                    failed("runtime_bind_failed", null)
                    return
                }
                service = Messenger(binder)
                val root = File(context.filesDir, "mgread-runtime/android").canonicalFile
                val dataRoot = File(context.filesDir, "mgread-runtime/data").canonicalFile
                val args = arrayListOf(
                    "node",
                    File(root, "dist/cli.js").path,
                    "--data-root=${dataRoot.path}",
                    "--debug-http-enabled=1",
                )
                val request = Message.obtain(null, AndroidNodeProcessIpc.START)
                request.replyTo = receiver
                request.data = Bundle().apply {
                    putStringArrayList(AndroidNodeProcessIpc.KEY_ARGUMENTS, args)
                    putInt(AndroidNodeProcessIpc.KEY_GENERATION, generation)
                }
                runCatching { service?.send(request) }.onFailure {
                    failed("runtime_start_failed", null)
                }
            }

            override fun onServiceDisconnected(name: ComponentName?) {
                if (connection !== this) return
                service = null
                ready = null
                binding = false
                runCatching { context.unbindService(this) }
                connection = null
                if (restartPending && !disposed) {
                    restartPending = false
                    terminalFailure = false
                    startupGeneration++
                    val pending = callbacks.toList()
                    callbacks.clear()
                    if (pending.isEmpty()) {
                        start { _, _ -> }
                    } else {
                        pending.forEach(::start)
                    }
                } else if (!disposed) {
                    failed("runtime_process_exited", null)
                }
            }
        }
        connection = candidate
        val ok = runCatching {
            context.bindService(
                Intent(context, AndroidNodeProcessService::class.java),
                candidate,
                Context.BIND_AUTO_CREATE,
            )
        }.getOrDefault(false)
        if (!ok) failed("runtime_bind_failed", null)
    }

    private fun line(kind: String, data: Bundle) {
        if (disposed || terminalFailure || restartPending) return
        val value = data.getString(AndroidNodeProcessIpc.KEY_LINE) ?: return
        onEvent(mapOf("type" to kind, "line" to value))
        if (kind != "node_stdout" || ready != null) return
        val record = runCatching { JSONObject(value) }.getOrNull() ?: return
        if (record.optString("type") != "ready") return
        if (record.optString("host") != "127.0.0.1" ||
            record.optString("nodeVersion") != MOBILE_NODE_VERSION ||
            record.optInt("port") !in 1..65535 ||
            record.optString("bootId").isEmpty()
        ) {
            failed("runtime_ready_invalid", null)
            return
        }
        ready = value
        binding = false
        val pending = callbacks.toList()
        callbacks.clear()
        pending.forEach { it(null, value) }
    }

    private fun failed(code: String, detail: String?) {
        if (restartPending && code == "runtime_process_exited") return
        if (disposed || (terminalFailure && callbacks.isEmpty())) return
        startupGeneration++
        terminalFailure = true
        binding = false
        ready = null
        service?.let { runCatching { it.send(Message.obtain(null, AndroidNodeProcessIpc.STOP)) } }
        service = null
        connection?.let { runCatching { context.unbindService(it) } }
        connection = null
        val pending = callbacks.toList()
        callbacks.clear()
        pending.forEach {
            it(AndroidRuntimeError(code, "Android Node process failed."), null)
        }
        onEvent(mapOf("type" to "node_exit", "code" to code, "detail" to detail))
    }

    fun restart(callback: (AndroidRuntimeError?, String?) -> Unit) {
        main.post {
            if (disposed) {
                callback(AndroidRuntimeError("runtime_unavailable", "Android Node process is closed."), null)
                return@post
            }
            callbacks += callback
            restartPending = true
            ready = null
            val remote = service
            if (remote == null) {
                connection?.let { runCatching { context.unbindService(it) } }
                connection = null
                restartPending = false
                binding = false
                terminalFailure = false
                startupGeneration++
                val pending = callbacks.toList()
                callbacks.clear()
                pending.forEach(::start)
            } else {
                runCatching { remote.send(Message.obtain(null, AndroidNodeProcessIpc.STOP)) }
                    .onFailure { failed("runtime_process_exited", null) }
                main.postDelayed({
                    if (restartPending && !disposed) {
                        connection?.let { runCatching { context.unbindService(it) } }
                        connection = null
                        service = null
                        binding = false
                        restartPending = false
                        terminalFailure = false
                        startupGeneration++
                        val pending = callbacks.toList()
                        callbacks.clear()
                        pending.forEach(::start)
                    }
                }, 3000L)
            }
        }
    }

    fun dispose() {
        main.post {
            if (disposed) return@post
            disposed = true
            startupGeneration++
            val pending = callbacks.toList()
            callbacks.clear()
            pending.forEach {
                it(AndroidRuntimeError("runtime_unavailable", "Android Node process is closed."), null)
            }
            service?.let { runCatching { it.send(Message.obtain(null, AndroidNodeProcessIpc.STOP)) } }
            connection?.let { runCatching { context.unbindService(it) } }
            service = null
            connection = null
            ready = null
            extraction.shutdownNow()
        }
    }

    private companion object {
        const val MOBILE_NODE_VERSION = "24.21.0"
        const val STARTUP_TIMEOUT_MILLIS = 30_000L
    }
}
