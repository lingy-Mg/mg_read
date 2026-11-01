/** Selects only a backend supported by the current process, including 32-bit
 * processes on ARMv8 hardware. Restored preferences cannot enable missing JNI.
 */
package com.mgread.mgread_plugin_runtime

internal class AndroidNodeBackendPolicy(
    val supportsJavet: Boolean,
    val supportsNodeProcess: Boolean,
) {
    fun supports(backend: String?): Boolean = when (backend) {
        "javet" -> supportsJavet
        "nodeProcess" -> supportsNodeProcess
        else -> false
    }

    fun selected(preference: String?): String = when {
        preference != null && supports(preference) -> preference
        supportsJavet -> "javet"
        supportsNodeProcess -> "nodeProcess"
        else -> error("No compatible Android Node runtime is packaged")
    }
}
