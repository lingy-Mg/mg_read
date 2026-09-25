/**
 * Fixed argument boundary between the main app and the remote Node service.
 *
 * The service accepts only the package-owned CLI, private data directory and
 * reviewed debug-listener capability. It does not accept arbitrary Node flags,
 * entrypoints or a caller-supplied working directory.
 */
package com.mgread.mgread_plugin_runtime

import java.io.File

internal object AndroidNodeLaunchContract {
    fun isValid(arguments: List<String>?, runtimeRoot: File, dataRoot: File): Boolean {
        if (arguments == null || arguments.size != 4) return false
        val entrypoint = File(runtimeRoot, "dist/cli.js")
        return entrypoint.isFile &&
            arguments[0] == "node" &&
            arguments[1] == entrypoint.path &&
            arguments[2] == "--data-root=${dataRoot.path}" &&
            arguments[3] == "--debug-http-enabled=1"
    }
}
