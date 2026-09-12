/**
 * Android plugin artifact transfer and Runtime inbox IO.
 *
 * Owns bounded byte-for-byte import/export sessions and artifact suffixes.
 * All methods are called only from AndroidRuntimeHost's dedicated Runtime thread.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.io.FileOutputStream
import java.util.UUID
import java.util.zip.CRC32

internal class AndroidPluginArtifactTransfer(
    private val context: Context,
) {
    private data class ImportSession(
        val target: File,
        val temporary: File,
        val expectedBytes: Long,
        val expectedChecksum: String,
        val output: FileOutputStream,
        var receivedBytes: Long = 0,
        val digest: CRC32 = CRC32(),
    )

    private data class ExportSession(val input: FileInputStream)

    private val importSessions = mutableMapOf<String, ImportSession>()
    private val exportSessions = mutableMapOf<String, ExportSession>()

    fun beginImport(
        pluginId: String,
        version: String,
        expectedBytes: Long,
        expectedChecksum: String,
        format: String,
    ): String {
        validateIdentity(pluginId, version, format)
        check(expectedBytes in 1..MAX_ARTIFACT_BYTES) { "file_too_large" }
        check(expectedChecksum.matches(Regex("[a-f0-9]{8}"))) { "invalid_request" }
        check(importSessions.size < MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
        val inbox = File(context.filesDir, "mgread-runtime/import-inbox").apply { mkdirs() }
        val id = UUID.randomUUID().toString().replace("-", "")
        val target = File(inbox, "transfer-$pluginId-$version-$id${artifactSuffix(format)}")
        val temporary = File(target.path + ".part")
        importSessions[id] = ImportSession(
            target = target,
            temporary = temporary,
            expectedBytes = expectedBytes,
            expectedChecksum = expectedChecksum,
            output = FileOutputStream(temporary, true),
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
        val digest = CRC32()
        file.inputStream().use { input ->
            val buffer = ByteArray(TRANSFER_CHUNK_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        val id = UUID.randomUUID().toString().replace("-", "")
        exportSessions[id] = ExportSession(file.inputStream())
        return mapOf(
            "id" to id,
            "bytes" to file.length(),
            "format" to format,
            "checksum" to digest.value.toString(16).padStart(8, '0'),
        )
    }

    fun readExportChunk(id: String): ByteArray {
        val session = exportSessions[id] ?: error("invalid_request")
        val output = ByteArray(TRANSFER_CHUNK_BYTES)
        val read = session.input.read(output)
        if (read < 0) {
            session.input.close()
            exportSessions.remove(id)
            return ByteArray(0)
        }
        return if (read == output.size) output else output.copyOf(read)
    }

    fun cancelExport(id: String) {
        exportSessions.remove(id)?.input?.close()
    }

    fun writeImportChunk(id: String, chunk: ByteArray) {
        val session = importSessions[id] ?: error("invalid_request")
        check(chunk.size <= TRANSFER_CHUNK_BYTES) { "invalid_request" }
        check(session.receivedBytes + chunk.size <= session.expectedBytes) {
            "plugin_transfer_size_mismatch"
        }
        session.temporary.parentFile?.mkdirs()
        session.output.write(chunk)
        session.digest.update(chunk)
        session.receivedBytes += chunk.size
    }

    fun finishImportBatch(ids: List<String>) {
        check(ids.isNotEmpty() && ids.size <= MAX_TRANSFER_BATCH) { "transfer_batch_too_large" }
        ids.forEach { id ->
            val session = importSessions[id] ?: error("invalid_request")
            check(session.receivedBytes == session.expectedBytes) { "plugin_transfer_size_mismatch" }
            val actual = session.digest.value.toString(16).padStart(8, '0')
            check(actual == session.expectedChecksum) { "plugin_transfer_checksum_mismatch" }
            session.output.close()
            check(session.temporary.renameTo(session.target)) { "disk_full" }
        }
        ids.forEach { importSessions.remove(it) }
    }

    fun cancelImports(ids: List<String>) {
        ids.forEach { id ->
            importSessions.remove(id)?.let { session ->
                session.output.close()
                session.temporary.delete()
            }
        }
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
