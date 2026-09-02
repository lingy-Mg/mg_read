/**
 * Host-owned direct HTTP transport for an Android WebView profile.
 *
 * Browser request values are assembled into the request headers in this file.
 */
package com.mgread.mgread_plugin_runtime

import java.io.ByteArrayOutputStream
import java.net.HttpURLConnection
import java.net.URI
import java.net.URL
import java.nio.charset.Charset
import java.util.concurrent.atomic.AtomicBoolean

internal data class AndroidBrowserHttpResponse(
    val body: String,
    val finalUrl: String,
    val headers: Map<String, String>,
    val setCookies: List<String>,
    val status: Int,
)

internal class AndroidBrowserResponseTooLarge : Exception()

internal object AndroidBrowserHttpTransport {
    fun execute(
        request: AndroidBrowserSessionRequest,
        cookie: String?,
        userAgent: String,
        cancelled: AtomicBoolean,
        onConnection: (HttpURLConnection?) -> Unit,
    ): AndroidBrowserHttpResponse {
        var url = request.url
        var method = request.method
        var body = request.body
        val setCookies = mutableListOf<String>()
        repeat(MAX_REDIRECTS + 1) { redirectIndex ->
            if (cancelled.get()) throw InterruptedException("cancelled")
            val connection = URL(url).openConnection() as HttpURLConnection
            onConnection(connection)
            try {
                connection.instanceFollowRedirects = false
                connection.requestMethod = method
                connection.connectTimeout = request.timeoutMs.coerceAtMost(Int.MAX_VALUE.toLong()).toInt()
                connection.readTimeout = connection.connectTimeout
                connection.useCaches = false
                connection.setRequestProperty("User-Agent", userAgent)
                if (!cookie.isNullOrBlank()) connection.setRequestProperty("Cookie", cookie)
                request.headers.forEach { (name, value) -> connection.setRequestProperty(name, value) }
                if (method == "POST") {
                    val encoded = body.orEmpty().toByteArray(Charsets.UTF_8)
                    connection.doOutput = true
                    connection.setFixedLengthStreamingMode(encoded.size)
                    connection.outputStream.use { it.write(encoded) }
                }
                val status = connection.responseCode
                connection.headerFields.entries
                    .filter { it.key?.equals("set-cookie", ignoreCase = true) == true }
                    .flatMapTo(setCookies) { it.value.orEmpty() }
                if (status in REDIRECT_STATUSES && redirectIndex < MAX_REDIRECTS) {
                    val location = connection.getHeaderField("Location")
                        ?: return response(connection, request.maxResponseBytes, setCookies)
                    val redirected = URI(url).resolve(location).toString()
                    require(originOf(redirected) == request.origin)
                    url = redirected
                    if (status == HttpURLConnection.HTTP_SEE_OTHER ||
                        ((status == HttpURLConnection.HTTP_MOVED_PERM ||
                            status == HttpURLConnection.HTTP_MOVED_TEMP) && method == "POST")
                    ) {
                        method = "GET"
                        body = null
                    }
                } else {
                    return response(connection, request.maxResponseBytes, setCookies)
                }
            } finally {
                onConnection(null)
                connection.disconnect()
            }
        }
        error("redirect_limit")
    }

    private fun response(
        connection: HttpURLConnection,
        maximumBytes: Int,
        setCookies: List<String>,
    ): AndroidBrowserHttpResponse {
        val bytes = readBounded(
            runCatching { connection.inputStream }.getOrNull() ?: connection.errorStream,
            maximumBytes,
        )
        val contentType = connection.contentType
        val charset = responseCharset(contentType)
        val headers = buildMap {
            for (name in RESPONSE_HEADERS) {
                connection.getHeaderField(name)?.takeIf { it.length <= 1024 }?.let {
                    put(name.lowercase(), it)
                }
            }
        }
        return AndroidBrowserHttpResponse(
            body = bytes.toString(charset),
            finalUrl = connection.url.toString(),
            headers = headers,
            setCookies = setCookies.toList(),
            status = connection.responseCode,
        )
    }

    private fun readBounded(
        stream: java.io.InputStream?,
        maximumBytes: Int,
    ): ByteArray {
        if (stream == null) return ByteArray(0)
        return stream.use { input ->
            val output = ByteArrayOutputStream(minOf(maximumBytes, 32 * 1024))
            val buffer = ByteArray(8 * 1024)
            var total = 0
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                total += read
                if (total > maximumBytes) throw AndroidBrowserResponseTooLarge()
                output.write(buffer, 0, read)
            }
            output.toByteArray()
        }
    }

    private fun responseCharset(contentType: String?): Charset {
        val name = CHARSET.find(contentType.orEmpty())?.groupValues?.getOrNull(1)
        return runCatching { if (name == null) Charsets.UTF_8 else Charset.forName(name) }
            .getOrDefault(Charsets.UTF_8)
    }

    private val REDIRECT_STATUSES = setOf(301, 302, 303, 307, 308)
    private val RESPONSE_HEADERS = listOf(
        "Cache-Control",
        "Content-Type",
        "ETag",
        "Expires",
        "Last-Modified",
    )
    private val CHARSET = Regex("charset=([^;\\s]+)", RegexOption.IGNORE_CASE)
    private const val MAX_REDIRECTS = 5
}
