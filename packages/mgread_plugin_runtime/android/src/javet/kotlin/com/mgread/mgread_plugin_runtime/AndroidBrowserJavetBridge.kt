/** Callback handoff from Android WebView to a Promise on the sole Javet thread.
 * Main-thread browser completion only enqueues strings and wakes the VM owner.
 * No polling, blocking browser wait or cross-thread V8 access is allowed.
 */
package com.mgread.mgread_plugin_runtime

import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8ValueFunction
import com.caoccao.javet.values.reference.V8ValuePromise

internal class AndroidBrowserJavetBridge(
    private val host: AndroidBrowserSessionHost,
    private val post: (() -> Unit) -> Boolean,
) : AutoCloseable {
    private val functions = mutableListOf<V8ValueFunction>()
    private val pending = mutableMapOf<String, V8ValuePromise>()

    fun install(runtime: NodeRuntime) {
        val start = JavetCallbackContext("__mgreadBrowserRequest", JavetCallbackType.DirectCallNoThisAndResult,
            object : IJavetDirectCallable.NoThisAndResult<Exception> {
                override fun call(vararg values: V8Value): V8Value {
                    val resolver = runtime.createV8ValuePromise()
                    val id = host.start(values.firstOrNull()?.toString().orEmpty())
                    pending[id] = resolver
                    val result = runtime.createV8ValueObject()
                    result.set("id", id)
                    resolver.promise.use { result.set("promise", it) }
                    host.awaitResult(id) { response ->
                        post {
                            pending.remove(id)?.use { current ->
                                runtime.createV8ValueString(response).use { current.resolve(it) }
                            }
                        }
                    }
                    return result
                }
            })
        bind(runtime, "__mgreadBrowserRequest", start)
        val cancel = JavetCallbackContext("__mgreadBrowserCancel", JavetCallbackType.DirectCallNoThisAndNoResult,
            object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                override fun call(vararg values: V8Value) { values.firstOrNull()?.toString()?.let(host::cancel) }
            })
        bind(runtime, "__mgreadBrowserCancel", cancel)
    }

    private fun bind(runtime: NodeRuntime, name: String, context: JavetCallbackContext) {
        runtime.createV8ValueFunction(context).also { runtime.getGlobalObject().set(name, it); functions += it }
    }

    override fun close() {
        pending.forEach { (id, resolver) -> host.cancel(id); host.forgetResult(id); runCatching { resolver.close() } }
        pending.clear()
        functions.forEach { runCatching { it.close() } }
        functions.clear()
    }
}
