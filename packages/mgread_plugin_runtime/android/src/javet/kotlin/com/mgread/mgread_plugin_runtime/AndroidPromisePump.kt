package com.mgread.mgread_plugin_runtime

/** Active Promise waiting on the Runtime's sole Javet thread.
 * Rechecks completion before sleeping, allows one immediate extra turn for
 * queued work, then backs off to the existing 10 ms ceiling for slow I/O.
 * The separate idle HTTP listener pump keeps its existing scheduling policy.
 */
internal object AndroidPromisePump {
    fun await(
        isPending: () -> Boolean,
        pump: () -> Unit,
        beforePump: () -> Unit = {},
        sleep: (Long) -> Unit = { Thread.sleep(it) },
    ) {
        var pendingTurns = 0
        while (isPending()) {
            beforePump()
            pump()
            if (!isPending()) return
            val delayMillis = when {
                pendingTurns == 0 -> 0L
                pendingTurns < 4 -> 1L
                pendingTurns < 8 -> 2L
                pendingTurns < 12 -> 5L
                else -> 10L
            }
            // Saturate so an indefinitely pending operation never wraps back
            // into the immediate-turn phase after integer overflow.
            if (pendingTurns < 12) pendingTurns++
            if (delayMillis > 0) sleep(delayMillis)
        }
    }
}
