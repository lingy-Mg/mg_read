package com.mgread.mgread_plugin_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Test

class AndroidNodeBackendPolicyTest {
    @Test fun armv7DefaultsToNodeProcessAndRejectsRestoredJavet() {
        val policy = AndroidNodeBackendPolicy(false, true)
        assertEquals("nodeProcess", policy.selected(null))
        assertEquals("nodeProcess", policy.selected("javet"))
        assertFalse(policy.supports("javet"))
    }

    @Test fun arm64RetainsTheSavedChoiceAndDefault() {
        val policy = AndroidNodeBackendPolicy(true, true)
        assertEquals("javet", policy.selected(null))
        assertEquals("nodeProcess", policy.selected("nodeProcess"))
    }

    @Test fun emulatorWithoutNodeLibraryUsesJavet() {
        val policy = AndroidNodeBackendPolicy(true, false)
        assertEquals("javet", policy.selected("nodeProcess"))
        assertFalse(policy.supports("nodeProcess"))
        assertFalse(policy.supports("unknown"))
    }
}
