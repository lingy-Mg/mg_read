/** Private polling bridge between the embedded Node Core and Android WebView. */
package com.mgread.mgread_plugin_runtime

import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8ValueFunction

internal class AndroidBrowserJavetBridge(
    private val host: AndroidBrowserSessionHost,
) : AutoCloseable {
    private val functions = mutableListOf<V8ValueFunction>()

    fun install(runtime: NodeRuntime) {
        installStringFunction(runtime, "__mgreadBrowserStart") { raw -> host.start(raw) }
        installStringFunction(runtime, "__mgreadBrowserPoll") { id -> host.poll(id) }
        val cancelContext = JavetCallbackContext(
            "__mgreadBrowserCancel",
            JavetCallbackType.DirectCallNoThisAndNoResult,
            object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                override fun call(vararg values: V8Value) {
                    values.firstOrNull()?.toString()?.let(host::cancel)
                }
            },
        )
        runtime.createV8ValueFunction(cancelContext).also { function ->
            runtime.getGlobalObject().set("__mgreadBrowserCancel", function)
            functions += function
        }
    }

    private fun installStringFunction(
        runtime: NodeRuntime,
        name: String,
        operation: (String) -> String,
    ) {
        val context = JavetCallbackContext(
            name,
            JavetCallbackType.DirectCallNoThisAndResult,
            object : IJavetDirectCallable.NoThisAndResult<Exception> {
                override fun call(vararg values: V8Value): V8Value {
                    val value = values.firstOrNull()?.toString().orEmpty()
                    return runtime.createV8ValueString(operation(value))
                }
            },
        )
        runtime.createV8ValueFunction(context).also { function ->
            runtime.getGlobalObject().set(name, function)
            functions += function
        }
    }

    override fun close() {
        functions.forEach { runCatching { it.close() } }
        functions.clear()
    }
}
