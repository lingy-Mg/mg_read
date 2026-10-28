package com.mgread.mgread_plugin_runtime

import android.os.ParcelFileDescriptor
import android.system.ErrnoException
import android.system.Os
import android.system.OsConstants
import com.caoccao.javet.interop.NodeRuntime
import com.caoccao.javet.interop.callback.IJavetDirectCallable
import com.caoccao.javet.interop.callback.JavetCallbackContext
import com.caoccao.javet.interop.callback.JavetCallbackType
import com.caoccao.javet.values.V8Value
import com.caoccao.javet.values.reference.V8ValueFunction
import java.util.concurrent.atomic.AtomicBoolean

/** Kernel pipe from Android producers to Node's libuv loop. Node owns the
 * detached read descriptor; this owner keeps and closes only the write end.
 * At most one outstanding byte is needed, so writes cannot fill the pipe.
 */
internal class AndroidJavetWakeup(private val onFailure: () -> Unit) : AutoCloseable {
    private val armed = AtomicBoolean(false)
    private var writer: ParcelFileDescriptor? = null
    private var consumed: V8ValueFunction? = null
    private var failed: V8ValueFunction? = null

    fun install(runtime: NodeRuntime) {
        val pipe = ParcelFileDescriptor.createPipe()
        try {
            writer = pipe[1]
            Os.fcntlInt(pipe[1].fileDescriptor, OsConstants.F_SETFL, OsConstants.O_NONBLOCK)
            val context = JavetCallbackContext("__mgreadWakeConsumed", JavetCallbackType.DirectCallNoThisAndNoResult,
                object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                    override fun call(vararg values: V8Value) { armed.set(false) }
                })
            consumed = runtime.createV8ValueFunction(context)
            runtime.getGlobalObject().set("__mgreadWakeConsumed", consumed)
            val failureContext = JavetCallbackContext("__mgreadWakeFailed", JavetCallbackType.DirectCallNoThisAndNoResult,
                object : IJavetDirectCallable.NoThisAndNoResult<Exception> {
                    override fun call(vararg values: V8Value) { onFailure() }
                })
            failed = runtime.createV8ValueFunction(failureContext)
            runtime.getGlobalObject().set("__mgreadWakeFailed", failed)
            // Socket adopts an existing pipe descriptor; there is no TCP listener,
            // thread-pool read, network permission or polling timer involved.
            val fd = pipe[0].detachFd()
            runtime.getExecutor("""
                globalThis.__mgreadWakeSocket = new (require('node:net').Socket)({fd:$fd,readable:true,writable:false});
                globalThis.__mgreadWakeSocket.on('data', () => globalThis.__mgreadWakeConsumed());
                globalThis.__mgreadWakeSocket.on('error', () => globalThis.__mgreadWakeFailed());
                globalThis.__mgreadWakeSocket.on('end', () => globalThis.__mgreadWakeFailed());
                globalThis.__mgreadWakeSocket.resume();
            """.trimIndent()).executeVoid()
        } finally {
            runCatching { pipe[0].close() }
        }
    }

    @Synchronized fun signal() {
        val output = writer ?: return
        if (!armed.compareAndSet(false, true)) return
        try {
            Os.write(output.fileDescriptor, byteArrayOf(1), 0, 1)
        } catch (error: ErrnoException) {
            if (error.errno != OsConstants.EAGAIN) {
                // EOF wakes libuv even if a producer can no longer write.
                runCatching { output.close() }
                writer = null
            }
        }
    }

    fun closeNode(runtime: NodeRuntime) {
        runtime.getExecutor("globalThis.__mgreadWakeSocket?.removeAllListeners(); globalThis.__mgreadWakeSocket?.destroy(); delete globalThis.__mgreadWakeSocket;").executeVoid()
        consumed?.close()
        consumed = null
        failed?.close()
        failed = null
    }

    @Synchronized override fun close() {
        writer?.close()
        writer = null
    }
}
