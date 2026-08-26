/**
 * Android plugin artifact transfer and Runtime inbox IO.
 *
 * Owns bounded byte-for-byte import/export sessions and artifact suffixes.
 * All methods are called only from AndroidRuntimeHost's dedicated Runtime thread.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import java.io.File
import java.io.FileOutputStream
import java.security.MessageDigest
import java.util.UUID

internal class AndroidPluginArtifactTransfer(
    private val context: Context,
) {
    private data class ImportSession(
        val target: File,
        val temporary: File,
        val expectedBytes: Long,
        val expectedSha256: String,
        var receivedBytes: Long = 0,
        val digest: MessageDigest = MessageDigest.getInstance("SHA-256"),
    )

    private data class ExportSession(val file: File, var offset: Long = 0)

    private val importSessions = mutableMapOf<String, ImportSession>()
    private val exportSessions = mutableMapOf<String, ExportSession>()

    fun beginImport(
        pluginId: String,
        version: String,
        expectedBytes: Long,
        expectedSha256: String,
        format: String,
    ): String {
        validateIdentity(pluginId, version, format)
        check(expectedBytes in 1..MAX_ARTIFACT_BYTES) { "file_too_large" }
        check(expectedSha256.matches(Regex("[a-f0-9]{64}"))) { "invalid_request" }
        check(importSessions.size < MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
        val inbox = File(context.filesDir, "mgread-runtime/import-inbox").apply { mkdirs() }
        val id = UUID.randomUUID().toString().replace("-", "")
        val target = File(inbox, "transfer-$pluginId-$version-$id${artifactSuffix(format)}")
        importSessions[id] = ImportSession(
            target = target,
            temporary = File(target.path + ".part"),
            expectedBytes = expectedBytes,
            expectedSha256 = expectedSha256,
        )
        return id
    }

    fun beginExport(
        dataRoot: File,
        pluginId: String,
        version: String,
        format: String,
    ): Map<String, Any?> {
        validateIdentity(pluginId, version, format)
        val file = File(
            dataRoot,
            "plugin-archives/$pluginId/$version${artifactSuffix(format)}",
        )
        check(file.isFile) { "plugin_transfer_artifact_missing" }
        check(file.length() in 1..MAX_ARTIFACT_BYTES) { "plugin_transfer_artifact_too_large" }
        val digest = MessageDigest.getInstance("SHA-256")
        file.inputStream().use { input ->
            val buffer = ByteArray(TRANSFER_CHUNK_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val id = UUID.randomUUID().toString().replace("-", "")
        exportSessions[id] = ExportSession(file)
        return mapOf(
            "id" to id,
            "bytes" to file.length(),
            "format" to format,
            "sha256" to digest.digest().joinToString("") { byte -> "%02x".format(byte) },
        )
    }

    fun readExportChunk(id: String): ByteArray {
        val session = exportSessions[id] ?: error("invalid_request")
        val remaining = session.file.length() - session.offset
        if (remaining <= 0) {
            exportSessions.remove(id)
            return ByteArray(0)
        }
        val count = minOf(remaining, TRANSFER_CHUNK_BYTES.toLong()).toInt()
        val output = ByteArray(count)
        session.file.inputStream().use { input ->
            check(input.skip(session.offset) == session.offset) { "plugin_transfer_artifact_missing" }
            var read = 0
            while (read < count) {
                val next = input.read(output, read, count - read)
                if (next < 0) break
                read += next
            }
            check(read == count) { "plugin_transfer_artifact_missing" }
        }
        session.offset += count
        return output
    }

    fun cancelExport(id: String) {
        exportSessions.remove(id)
    }

    fun writeImportChunk(id: String, chunk: ByteArray) {
        val session = importSessions[id] ?: error("invalid_request")
        check(chunk.size <= TRANSFER_CHUNK_BYTES) { "invalid_request" }
        check(session.receivedBytes + chunk.size <= session.expectedBytes) {
            "plugin_transfer_size_mismatch"
        }
        session.temporary.parentFile?.mkdirs()
        FileOutputStream(session.temporary, true).use { output -> output.write(chunk) }
        session.digest.update(chunk)
        session.receivedBytes += chunk.size
    }

    fun finishImportBatch(ids: List<String>) {
        check(ids.isNotEmpty() && ids.size <= MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
        ids.forEach { id ->
            val session = importSessions[id] ?: error("invalid_request")
            check(session.receivedBytes == session.expectedBytes) { "plugin_transfer_size_mismatch" }
            val actual = session.digest.digest().joinToString("") { byte -> "%02x".format(byte) }
            check(actual == session.expectedSha256) { "plugin_transfer_checksum_mismatch" }
            check(session.temporary.renameTo(session.target)) { "disk_full" }
        }
        ids.forEach { importSessions.remove(it) }
    }

    fun cancelImports(ids: List<String>) {
        ids.forEach { id -> importSessions.remove(id)?.temporary?.delete() }
    }

    private fun validateIdentity(pluginId: String, version: String, format: String) {
        check(pluginId.matches(Regex("[a-z0-9][a-z0-9.-]{0,127}"))) { "invalid_request" }
        check(version.matches(Regex("\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?"))) { "invalid_request" }
        check(format == "singleFile" || format == "archive") { "invalid_request" }
    }

    private companion object {
        const val MAX_ARTIFACT_BYTES = 32L * 1024L * 1024L
        const val MAX_TRANSFER_BATCH = 32
        const val TRANSFER_CHUNK_BYTES = 64 * 1024
    }
}

private fun artifactSuffix(format: String): String = when (format) {
    "singleFile" -> ".mgplugin.js"
    "archive" -> ".mgplugin"
    else -> error("invalid_request")
}
