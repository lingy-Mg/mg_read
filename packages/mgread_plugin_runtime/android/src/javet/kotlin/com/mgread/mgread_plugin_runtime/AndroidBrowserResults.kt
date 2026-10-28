package com.mgread.mgread_plugin_runtime

/** Thread-safe completion handoff. Javet subscribes once; the Node process
 * adapter can still consume an already completed result through its old API.
 * Resolve/register races deliver once, and callbacks run outside the lock.
 */
internal class AndroidBrowserResults {
    private val completed = mutableMapOf<String, String>()
    private val listeners = mutableMapOf<String, (String) -> Unit>()
    private val abandoned = mutableSetOf<String>()

    fun complete(id: String, result: String) {
        val listener = synchronized(this) {
            if (abandoned.remove(id)) return
            listeners.remove(id).also { if (it == null) completed[id] = result }
        }
        listener?.invoke(result)
    }

    fun listen(id: String, listener: (String) -> Unit) {
        val result = synchronized(this) {
            completed.remove(id).also { if (it == null) listeners[id] = listener }
        }
        result?.let(listener)
    }

    @Synchronized fun take(id: String): String? = completed.remove(id)
    @Synchronized fun forget(id: String) {
        if (listeners.remove(id) != null) abandoned.add(id)
        completed.remove(id)
    }
}
