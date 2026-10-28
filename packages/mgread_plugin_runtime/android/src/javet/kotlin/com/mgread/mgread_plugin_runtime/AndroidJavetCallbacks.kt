package com.mgread.mgread_plugin_runtime

import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8ValueFunction

/** Promise reactions retained by JS; only plain result strings cross callbacks.
 * Completion is queued after the native stack unwinds. No Promise polling,
 * per-request V8 handle retention or lifecycle transitions from inside JNI.
 */
internal class AndroidJavetCallbacks(
    private val runtime: NodeRuntime,
    private val post: (() -> Unit) -> Boolean,
) : AutoCloseable {
    private val waiting = mutableMapOf<String, (Boolean, String?) -> Unit>()
    private var sequence = 0L
    private val complete: V8ValueFunction
    private val observe: V8ValueFunction

    init {
        val context = JavetCallbackContext("__mgreadAsyncComplete", JavetCallbackType.DirectCallNoThisAndNoResult,
            object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                override fun call(vararg values: V8Value) {
                    val token = values[0].toString()
                    val ok = values[1].toString() == "true"
                    val result = if (values[2].isNullOrUndefined) null else values[2].toString()
                    post { waiting.remove(token)?.invoke(ok, result) }
                }
            })
        complete = runtime.createV8ValueFunction(context)
        runtime.getGlobalObject().set("__mgreadAsyncComplete", complete)
        observe = runtime.getExecutor("""
            ((token, value) => {
              Promise.resolve(value).then(
                result => globalThis.__mgreadAsyncComplete(token, true, result == null ? null : String(result)),
                () => globalThis.__mgreadAsyncComplete(token, false, null));
            })
        """.trimIndent()).execute<V8ValueFunction>()
    }

    fun observe(value: V8Value, callback: (Boolean, String?) -> Unit): String {
        val token = "promise-${++sequence}"
        waiting[token] = callback
        try { value.use { observe.callVoid(null, token, it) } }
        catch (_: Throwable) { waiting.remove(token); callback(false, null) }
        return token
    }

    fun forget(token: String?) { if (token != null) waiting.remove(token) }

    override fun close() {
        waiting.clear()
        try { observe.close() } finally { complete.close() }
    }
}
