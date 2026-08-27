package com.mgread.mgread_plugin_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidBrowserSessionContractTest {
    @Test
    fun normalizesSecureOriginsWithoutLosingNonDefaultPorts() {
        assertEquals("https://example.com", originOf("https://EXAMPLE.com/protected"))
        assertEquals("https://example.com:8443", originOf("https://example.com:8443/"))
    }

    @Test
    fun detectsChallengeWithoutTreatingOrdinaryHtmlAsVerifiedEvidence() {
        assertTrue(looksLikeCloudflareChallenge("<title>Just a moment...</title>"))
        assertEquals(false, looksLikeCloudflareChallenge("<title>Book detail</title>"))
    }
}
