package com.mgread.mgread_plugin_runtime

import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidRuntimeBackendGateTest {
    @Test
    fun oneApplicationProcessKeepsItsFirstBackend() {
        val gate = AndroidRuntimeBackendGate()
        assertTrue(gate.claim(AndroidRuntimeBackend.NODE_PROCESS))
        assertTrue(gate.claim(AndroidRuntimeBackend.NODE_PROCESS))
        assertFalse(gate.claim(AndroidRuntimeBackend.JAVET))
    }
}
