/**
 * Application-process backend selection shared by both private Flutter channels.
 *
 * A process may select Javet or the remote Node service once. Disposal does
 * not permit the same app process to start a second backend.
 */
package com.mgread.mgread_plugin_runtime

internal enum class AndroidRuntimeBackend { JAVET, NODE_PROCESS }

internal class AndroidRuntimeBackendGate {
    private var selected: AndroidRuntimeBackend? = null

    @Synchronized
    fun claim(backend: AndroidRuntimeBackend): Boolean {
        if (selected == null) selected = backend
        return selected == backend
    }
}
