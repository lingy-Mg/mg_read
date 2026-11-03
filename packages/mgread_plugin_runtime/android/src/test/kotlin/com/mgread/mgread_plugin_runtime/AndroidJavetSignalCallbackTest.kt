package com.mgread.mgread_plugin_runtime

import com.caoccao.javet.interop.callback.IJavetDirectCallable
import org.junit.Assert.assertEquals
import org.junit.Test

/** Exercises Javet's null zero-argument array through its Java callback API.
 * Both wake consumption and pipe failure use this adapter in production.
 */
class AndroidJavetSignalCallbackTest {
    @Test fun zeroArgumentNativeCallsDeliverEverySignal() {
        var signals = 0
        val callback = AndroidJavetSignalCallback { signals++ }
        callback.call(null)
        val javaCallback: IJavetDirectCallable.NoThisAndNoResult<Exception> = callback
        javaCallback.call(*emptyArray())
        callback.call(null)
        assertEquals(3, signals)
    }
}
