/**
 * JNI entrypoint for the isolated native Runtime service.
 *
 * The Rust host owns its loopback HTTP listener and runs independently of the
 * Flutter main process. The Android service process is its lifecycle boundary.
 */
package com.mgread.mgread_plugin_runtime

internal object NativeRuntime {
    init {
        System.loadLibrary("mgread_native_runtime")
    }

    external fun start(root: String, token: String): String
}
