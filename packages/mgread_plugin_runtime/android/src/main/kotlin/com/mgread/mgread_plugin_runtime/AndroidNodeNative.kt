/**
 * JNI boundary for the pinned Android arm64 Node shared library.
 *
 * Only AndroidNodeProcessService calls [run], on its dedicated thread. The
 * bridge library is loaded in that remote process, so Javet stays in the main
 * application process when selected instead.
 */
package com.mgread.mgread_plugin_runtime

internal object AndroidNodeNative {
    init {
        System.loadLibrary("mgread_node_bridge")
    }

    external fun run(
        arguments: Array<String>,
        home: String,
        temporaryDirectory: String,
        workingDirectory: String,
        stdoutFd: Int,
        stderrFd: Int,
    ): Int
}
