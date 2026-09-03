/**
 * Android browser-session wire contract.
 *
 * This is a second validation layer for the private Javet bridge. It accepts
 * only reviewed v1 fields. The additive single-page API accepts script source
 * as data but never accepts Cookie, profile handles, or WebView settings.
 */
package com.mgread.mgread_plugin_runtime

import org.json.JSONObject
import java.net.URI

internal data class AndroidBrowserSessionRequest(
    val action: String,
    val body: String?,
    val headers: Map<String, String>,
    val interaction: String,
    val maxResponseBytes: Int,
    val method: String,
    val operation: String,
    val pluginId: String,
    val pluginName: String = pluginId,
    val presentation: String,
    val selector: String,
    val sessionKey: String,
    val text: String?,
    val timeoutMs: Long,
    val transport: String,
    val url: String,
    val pageParams: JSONObject? = null,
) {
    val origin: String = if (url.isEmpty()) "" else originOf(url)

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
            val operation = value.optString("operation", "request")
            if (operation.startsWith("page.") || operation == "debug") {
                return parsePage(value, pluginId, operation)
            }
            val sessionKey = value.requiredString("sessionKey", 64)
            require(SESSION_KEY.matches(sessionKey))
            val url = value.requiredString("url", 4096)
            originOf(url)
            require(operation == "request" || operation == "interaction")
            if (operation == "interaction") {
                val action = value.requiredString("action", 16)
                require(action == "coordinates" || action == "native-input" || action == "control-click")
                val presentation = value.requiredString("presentation", 7)
                require(presentation == "hidden" || presentation == "visible")
                val timeoutMs = value.optLong("timeoutMs", -1L)
                require(timeoutMs in 1_000L..MAX_TIMEOUT_MILLIS)
                val selector = value.requiredString("selector", 512)
                val text = if (value.isNull("text")) null else value.optString("text", "")
                require(action != "native-input" || (text != null && text.length <= 16 * 1024))
                require(action == "native-input" || text == null)
                return AndroidBrowserSessionRequest(
                    action = action,
                    body = null,
                    headers = emptyMap(),
                    interaction = "allow",
                    maxResponseBytes = 1,
                    method = "GET",
                    operation = operation,
                    pluginId = pluginId,
                    pluginName = pluginId,
                    presentation = presentation,
                    selector = selector,
                    sessionKey = sessionKey,
                    text = text,
                    timeoutMs = timeoutMs,
                    transport = "webview",
                    url = url,
                )
            }
            val method = value.requiredString("method", 4)
            require(method == "GET" || method == "POST")
            val interaction = value.requiredString("interaction", 8)
            require(interaction == "allow" || interaction == "silent")
            val presentation = value.requiredString("presentation", 7)
            require(presentation == "hidden" || presentation == "visible")
            val transport = value.requiredString("transport", 7)
            require(transport == "html" || transport == "http" || transport == "webview")
            val timeoutMs = value.optLong("timeoutMs", -1L)
            require(timeoutMs in 1_000L..MAX_TIMEOUT_MILLIS)
            val maxResponseBytes = value.optInt("maxResponseBytes", -1)
            require(maxResponseBytes in 1..MAX_RESPONSE_BYTES)
            val body = if (value.isNull("body")) null else value.getString("body")
            require(method != "GET" || body == null)
            val headers = parseHeaders(value.getJSONObject("headers"), url)
            return AndroidBrowserSessionRequest(
                action = "",
                body = body,
                headers = headers,
                interaction = interaction,
                maxResponseBytes = maxResponseBytes,
                method = method,
                operation = operation,
                pluginId = pluginId,
                pluginName = pluginId,
                presentation = presentation,
                selector = "",
                sessionKey = sessionKey,
                text = null,
                timeoutMs = timeoutMs,
                transport = transport,
                url = url,
            )
        }

        private fun parsePage(
            value: JSONObject,
            pluginId: String,
            operation: String,
        ): AndroidBrowserSessionRequest {
            require(operation in PAGE_OPERATIONS)
            val timeoutMs = value.optLong("timeoutMs", -1L)
            require(timeoutMs in 1L..MAX_TIMEOUT_MILLIS)
            val pluginName = value.requiredString("pluginName", 128)
            val url = when (operation) {
                "page.navigate", "page.fetch" -> value.requiredHttpUrl("url")
                else -> ""
            }
            when (operation) {
                "debug" -> {
                    val action = value.requiredString("action", 8)
                    require(action == "enter" || action == "show")
                }
                "page.open" -> require(value.opt("visible") is Boolean)
                "page.evaluate" -> value.requiredString("code", 512 * 1024)
                "page.cdp" -> {
                    value.requiredString("method", 256)
                    require(value.opt("params") is JSONObject)
                    require(value.getJSONObject("params").toString().toByteArray(Charsets.UTF_8).size <= 512 * 1024)
                }
                "page.fetch" -> {
                    val method = value.requiredString("method", 32)
                    require(METHOD.matches(method))
                    require(value.optString("responseType") in setOf("text", "json", "base64"))
                    require(value.opt("headers") is JSONObject)
                    value.getJSONObject("headers").keys().forEach { name ->
                        require(name.isNotBlank() && name.length <= 256)
                        require(value.getJSONObject("headers").getString(name).length <= 64 * 1024)
                    }
                    require(value.isNull("body") || value.opt("body") is String)
                }
                "page.click" -> {
                    require(value.optDouble("x", Double.NaN).let { it.isFinite() && it in 0.0..100_000.0 })
                    require(value.optDouble("y", Double.NaN).let { it.isFinite() && it in 0.0..100_000.0 })
                }
                "page.input" -> value.requiredString("text", 64 * 1024)
                "page.key" -> {
                    require(value.optString("key") in PAGE_KEYS)
                    val modifiers = value.optJSONArray("modifiers") ?: throw IllegalArgumentException()
                    require(modifiers.length() <= 3)
                    repeat(modifiers.length()) { require(modifiers.getString(it) in PAGE_MODIFIERS) }
                }
                "page.waitText" -> {
                    value.requiredString("text", 64 * 1024)
                    require(value.optString("scope") in setOf("text", "html"))
                }
            }
            return AndroidBrowserSessionRequest(
                action = "",
                body = null,
                headers = emptyMap(),
                interaction = "silent",
                maxResponseBytes = MAX_RESPONSE_BYTES,
                method = "GET",
                operation = operation,
                pluginId = pluginId,
                pluginName = pluginName,
                presentation = "hidden",
                selector = "",
                sessionKey = "",
                text = null,
                timeoutMs = timeoutMs,
                transport = "webview",
                url = url,
                pageParams = value,
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

private fun JSONObject.requiredHttpUrl(name: String): String {
    val value = requiredString(name, 4096)
    val uri = URI(value)
    require((uri.scheme == "https" || uri.scheme == "http") && uri.rawUserInfo == null && uri.host != null)
    return uri.toString()
}

internal fun originOf(value: String): String {
    val uri = URI(value)
    require(uri.scheme == "https" && uri.rawUserInfo == null && uri.host != null)
    val port = if (uri.port == -1 || uri.port == 443) "" else ":${uri.port}"
    return "https://${uri.host.lowercase()}$port"
}

private fun JSONObject.requiredString(name: String, maximumLength: Int): String {
    val value = getString(name)
    require(value.isNotBlank() && value.length <= maximumLength)
    return value
}

private val PLUGIN_ID = Regex("^[a-z0-9]+(?:[._-][a-z0-9]+)+$")
private val SESSION_KEY = Regex("^[A-Za-z0-9._-]{1,64}$")
private val METHOD = Regex("^[A-Z]+$")
private val PAGE_OPERATIONS = setOf(
    "debug",
    "page.open", "page.show", "page.hide", "page.close", "page.navigate",
    "page.evaluate", "page.html", "page.fetch", "page.click", "page.input",
    "page.key", "page.cdp", "page.waitText", "page.getUrl",
)
private val PAGE_KEYS = setOf(
    "Enter", "Tab", "Escape", "ArrowUp", "ArrowDown", "ArrowLeft", "ArrowRight",
    "PageUp", "PageDown", "Home", "End", "Backspace", "Delete",
)
private val PAGE_MODIFIERS = setOf("alt", "control", "shift")
private const val MAX_REQUEST_BYTES = 1024 * 1024
private const val MAX_RESPONSE_BYTES = 2 * 1024 * 1024
private const val MAX_TIMEOUT_MILLIS = 120_000L
