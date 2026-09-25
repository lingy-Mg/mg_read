/**
 * Private Android service that owns one full Node CLI in a separate process.
 *
 * Its Messenger carries only bounded stdout/stderr records and lifecycle
 * notices. Capability requests and resources remain on the Runtime Core's
 * authenticated loopback protocol. The service never creates a WebView.
 */
package com.mgread.mgread_plugin_runtime

import android.app.Service
import android.content.Intent
import android.os.Bundle
import android.os.Handler
import android.os.IBinder
import android.os.Looper
import android.os.Message
import android.os.Messenger
import android.os.ParcelFileDescriptor
import android.os.Process
import java.io.BufferedInputStream
import java.io.ByteArrayOutputStream
import java.io.File
import java.io.FileInputStream
import java.util.concurrent.atomic.AtomicBoolean

internal object AndroidNodeProcessIpc {
    const val START = 1
    const val STOP = 2
    const val STDOUT = 3
    const val STDERR = 4
    const val EXIT = 5
    const val ERROR = 6
    const val KEY_ARGUMENTS = "arguments"
    const val KEY_GENERATION = "generation"
    const val KEY_LINE = "line"
    const val KEY_CODE = "code"
    const val MAX_LINE_BYTES = 64 * 1024
}

class AndroidNodeProcessService : Service() {
    private val launched = AtomicBoolean(false)
    private val incoming = Messenger(object : Handler(Looper.getMainLooper()) {
        override fun handleMessage(message: Message) {
            when (message.what) {
                AndroidNodeProcessIpc.START -> start(message)
                AndroidNodeProcessIpc.STOP -> Process.killProcess(Process.myPid())
                else -> super.handleMessage(message)
            }
        }
    })

    override fun onBind(intent: Intent?): IBinder = incoming.binder

    private fun start(message: Message) {
        val callback = message.replyTo ?: return
        val generation = message.data.getInt(AndroidNodeProcessIpc.KEY_GENERATION, -1)
        if (generation <= 0) return
        if (!launched.compareAndSet(false, true)) {
            send(callback, AndroidNodeProcessIpc.ERROR, generation, code = "runtime_already_started")
            return
        }
        val arguments = message.data.getStringArrayList(AndroidNodeProcessIpc.KEY_ARGUMENTS)
        val root = File(filesDir, "mgread-runtime/android").canonicalFile
        val dataRoot = File(filesDir, "mgread-runtime/data").canonicalFile
        if (!AndroidNodeLaunchContract.isValid(arguments, root, dataRoot)) {
            send(callback, AndroidNodeProcessIpc.ERROR, generation, code = "runtime_launch_invalid")
            launched.set(false)
            return
        }
        val launchArguments = requireNotNull(arguments)
        val temporary = File(cacheDir, "mgread-node").apply { mkdirs() }
        dataRoot.mkdirs()
        val stdoutPipe = ParcelFileDescriptor.createPipe()
        val stderrPipe = ParcelFileDescriptor.createPipe()
        readLines(stdoutPipe[0], AndroidNodeProcessIpc.STDOUT, callback, generation)
        readLines(stderrPipe[0], AndroidNodeProcessIpc.STDERR, callback, generation)
        Thread({
            val exitCode = try {
                AndroidNodeNative.run(
                    launchArguments.toTypedArray(),
                    dataRoot.path,
                    temporary.path,
                    root.path,
                    stdoutPipe[1].detachFd(),
                    stderrPipe[1].detachFd(),
                )
            } catch (_: Throwable) {
                -10
            } finally {
                stdoutPipe[1].close()
                stderrPipe[1].close()
            }
            send(callback, AndroidNodeProcessIpc.EXIT, generation, code = exitCode.toString())
            Process.killProcess(Process.myPid())
        }, "mgread-node-main").start()
    }

    private fun readLines(pipe: ParcelFileDescriptor, kind: Int, callback: Messenger, generation: Int) {
        Thread({
            pipe.use { descriptor ->
                BufferedInputStream(FileInputStream(descriptor.fileDescriptor)).use { input ->
                    val line = ByteArrayOutputStream()
                    var dropped = false
                    while (true) {
                        val next = input.read()
                        if (next < 0) break
                        if (next == '\n'.code) {
                            if (!dropped && line.size() > 0) {
                                send(callback, kind, generation, line = line.toString(Charsets.UTF_8.name()))
                            }
                            line.reset()
                            dropped = false
                        } else if (!dropped) {
                            if (line.size() < AndroidNodeProcessIpc.MAX_LINE_BYTES) {
                                line.write(next)
                            } else {
                                line.reset()
                                dropped = true
                            }
                        }
                    }
                }
            }
        }, "mgread-node-output-$kind").start()
    }

    private fun send(callback: Messenger, kind: Int, generation: Int, line: String? = null, code: String? = null) {
        val message = Message.obtain(null, kind)
        message.data = Bundle().apply {
            putInt(AndroidNodeProcessIpc.KEY_GENERATION, generation)
            if (line != null) putString(AndroidNodeProcessIpc.KEY_LINE, line)
            if (code != null) putString(AndroidNodeProcessIpc.KEY_CODE, code)
        }
        runCatching { callback.send(message) }
    }

    override fun onDestroy() {
        super.onDestroy()
        // This is a dedicated process. Losing the owner must not orphan Node.
        Process.killProcess(Process.myPid())
    }
}
