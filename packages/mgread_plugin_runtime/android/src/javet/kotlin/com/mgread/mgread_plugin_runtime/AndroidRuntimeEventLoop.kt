package com.mgread.mgread_plugin_runtime

import java.util.concurrent.LinkedBlockingQueue
import java.util.concurrent.atomic.AtomicBoolean

/** Sole owner thread for Javet commands and libuv. A pipe wakes the blocking
 * native driver; before VM creation the queue itself provides the blocking wait.
 * No command, timer callback or WebView callback accesses V8 on another thread.
 */
internal class AndroidRuntimeEventLoop(private val onFailure: () -> Unit) {
    private val queue = LinkedBlockingQueue<() -> Unit>()
    private val accepting = AtomicBoolean(true)
    private var driver: ((Boolean) -> Unit)? = null
    @Volatile private var wake: (() -> Unit)? = null
    private val thread = Thread({ run() }, "mgread-node-runtime").apply { isDaemon = true; start() }

    @Synchronized fun post(action: () -> Unit): Boolean {
        if (!accepting.get()) return false
        queue.add(action)
        wake?.invoke()
        return true
    }

    fun setDriver(pump: ((Boolean) -> Unit)?, signal: (() -> Unit)? = null) {
        check(Thread.currentThread() === thread)
        driver = pump
        wake = signal
    }

    fun hasCommands(): Boolean = queue.isNotEmpty()

    @Synchronized fun shutdown() {
        accepting.set(false)
        queue.add({})
        wake?.invoke()
    }

    private fun run() {
        while (accepting.get() || queue.isNotEmpty()) {
            try {
                var command = queue.poll()
                if (command == null && driver == null && accepting.get()) command = queue.take()
                var turns = 0
                while (command != null) {
                    command.invoke()
                    if (++turns == 64) break
                    command = queue.poll()
                }
                if (accepting.get()) driver?.invoke(queue.isEmpty())
            } catch (_: Throwable) {
                // Javet Throwable must never be formatted or retained as cause.
                driver = null
                wake = null
                onFailure()
            }
        }
    }
}
