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

    @Test
    fun acceptsRenderedHtmlTransport() {
        val request = AndroidBrowserSessionRequest(
            action = "",
            body = null,
            headers = mapOf("accept" to "text/html"),
            interaction = "silent",
            maxResponseBytes = 4096,
            method = "GET",
            operation = "request",
            pluginId = "org.mgread.fixture",
            presentation = "hidden",
            selector = "",
            sessionKey = "fixture",
            text = null,
            timeoutMs = 5000L,
            transport = "html",
            url = "https://example.com/",
        )
        assertEquals("html", request.transport)
    }
}
