/**
 * Android browser-session wire contract.
 *
 * This is a second validation layer for the private Javet bridge. It accepts
 * only the reviewed v1 fields and never accepts Cookie, user-agent, script, or
 * arbitrary WebView settings from plugin code.
 */
package com.mgread.mgread_plugin_runtime

import org.json.JSONObject
import java.net.URI

internal data class AndroidBrowserSessionRequest(
    val body: String?,
    val headers: Map<String, String>,
    val interaction: String,
    val maxResponseBytes: Int,
    val method: String,
    val pluginId: String,
    val presentation: String,
    val sessionKey: String,
    val timeoutMs: Long,
    val transport: String,
    val url: String,
) {
    val origin: String = originOf(url)

    companion object {
        private val allowedHeaders = setOf(
            "accept",
            "accept-language",
            "content-type",
            "origin",
            "referer",
        )

        fun parse(raw: String): AndroidBrowserSessionRequest {
            require(raw.toByteArray(Charsets.UTF_8).size <= MAX_REQUEST_BYTES)
            val value = JSONObject(raw)
            require(value.optInt("version", -1) == 1)
            val pluginId = value.requiredString("pluginId", 160)
            require(PLUGIN_ID.matches(pluginId))
            val sessionKey = value.requiredString("sessionKey", 64)
            require(SESSION_KEY.matches(sessionKey))
            val url = value.requiredString("url", 4096)
            originOf(url)
            val method = value.requiredString("method", 4)
            require(method == "GET" || method == "POST")
            val interaction = value.requiredString("interaction", 8)
            require(interaction == "allow" || interaction == "silent")
            val presentation = value.requiredString("presentation", 7)
            require(presentation == "hidden" || presentation == "visible")
            val transport = value.requiredString("transport", 7)
            require(transport == "http" || transport == "webview")
            val timeoutMs = value.optLong("timeoutMs", -1L)
            require(timeoutMs in 1_000L..MAX_TIMEOUT_MILLIS)
            val maxResponseBytes = value.optInt("maxResponseBytes", -1)
            require(maxResponseBytes in 1..MAX_RESPONSE_BYTES)
            val body = if (value.isNull("body")) null else value.getString("body")
            require(method != "GET" || body == null)
            val headers = parseHeaders(value.getJSONObject("headers"), url)
            return AndroidBrowserSessionRequest(
                body = body,
                headers = headers,
                interaction = interaction,
                maxResponseBytes = maxResponseBytes,
                method = method,
                pluginId = pluginId,
                presentation = presentation,
                sessionKey = sessionKey,
                timeoutMs = timeoutMs,
                transport = transport,
                url = url,
            )
        }

        private fun parseHeaders(value: JSONObject, url: String): Map<String, String> {
            require(value.length() <= 16)
            val requestOrigin = originOf(url)
            return buildMap {
                value.keys().forEach { name ->
                    val normalized = name.lowercase()
                    require(normalized in allowedHeaders)
                    val header = value.getString(name)
                    require(header.length <= 1024)
                    if (normalized == "origin" || normalized == "referer") {
                        require(originOf(URI(url).resolve(header).toString()) == requestOrigin)
                    }
                    put(normalized, header)
                }
            }
        }
    }
}

internal fun originOf(value: String): String {
    val uri = URI(value)
    require(uri.scheme == "https" && uri.rawUserInfo == null && uri.host != null)
    val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
    return "https://${uri.host.lowercase()}$port"
}

internal fun looksLikeCloudflareChallenge(value: String): Boolean =
    CLOUDFLARE_MARKERS.containsMatchIn(value)

private fun JSONObject.requiredString(name: String, maximumLength: Int): String {
    val value = getString(name)
    require(value.isNotBlank() && value.length <= maximumLength)
    return value
}

private val PLUGIN_ID = Regex("^[a-z0-9]+(?:[._-][a-z0-9]+)+$")
private val SESSION_KEY = Regex("^[A-Za-z0-9._-]{1,64}$")
private val CLOUDFLARE_MARKERS = Regex(
    "cf-challenge|cf-turnstile|just a moment|checking your browser|challenge-platform",
    RegexOption.IGNORE_CASE,
)
private const val MAX_REQUEST_BYTES = 64 * 1024
private const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
private const val MAX_TIMEOUT_MILLIS = 120_000L
