/**
 * Android plugin artifact transfer and Runtime inbox IO.
 *
 * Owns Android-private staging paths, artifact metadata and import/export
 * sessions. Dart writes imports to the returned .part paths; this class checks
 * the completed files and publishes the full batch before one Core restart.
 * Each host calls this from its serial IO thread.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.zip.CRC32

internal class AndroidPluginArtifactTransfer(
    private val inboxDirectory: File,
) {
    constructor(context: Context) : this(File(context.filesDir, "mgread-runtime/import-inbox"))

    private data class ImportSession(
        val target: File,
        val temporary: File,
        val expectedBytes: Long,
        val expectedChecksum: String,
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
    ): Map<String, String> {
        validateIdentity(pluginId, version, format)
        check(expectedBytes in 1..MAX_ARTIFACT_BYTES) { "file_too_large" }
        check(expectedChecksum.matches(Regex("[a-f0-9]{8}"))) { "invalid_request" }
        check(importSessions.values.sumOf { it.expectedBytes } + expectedBytes <= MAX_TRANSFER_BATCH_BYTES) {
            "transfer_batch_too_large"
        }
        val inbox = inboxDirectory.apply { mkdirs() }
        val id = UUID.randomUUID().toString().replace("-", "")
        val target = File(inbox, "transfer-$pluginId-$version-$id${artifactSuffix(format)}")
        val temporary = File(target.path + ".part")
        importSessions[id] = ImportSession(
            target = target,
            temporary = temporary,
            expectedBytes = expectedBytes,
            expectedChecksum = expectedChecksum,
        )
        return mapOf("id" to id, "temporaryPath" to temporary.absolutePath)
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
            val buffer = ByteArray(IO_BUFFER_BYTES)
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
        val output = ByteArray(EXPORT_CHUNK_BYTES)
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

    fun finishImportBatch(ids: List<String>) {
        check(ids.isNotEmpty() && ids.size == ids.toSet().size) { "invalid_request" }
        // Check every file before renaming any: a corrupt last file must not
        // leave earlier files available to a later unrelated Runtime restart.
        ids.forEach { id ->
            val session = importSessions[id] ?: error("invalid_request")
            check(session.temporary.isFile && session.temporary.length() == session.expectedBytes) {
                "plugin_transfer_size_mismatch"
            }
            val actual = checksum(session.temporary).toString(16).padStart(8, '0')
            check(actual == session.expectedChecksum) { "plugin_transfer_checksum_mismatch" }
        }
        try {
            ids.forEach { id ->
                val session = importSessions.getValue(id)
                check(session.temporary.renameTo(session.target)) { "disk_full" }
            }
        } catch (error: Throwable) {
            cancelImports(ids)
            throw error
        }
        ids.forEach { importSessions.remove(it) }
    }

    fun cancelImports(ids: List<String>) {
        ids.forEach { id ->
            importSessions.remove(id)?.let { session ->
                session.temporary.delete()
                session.target.delete()
            }
        }
    }

    private fun checksum(file: File): Long {
        val digest = CRC32()
        file.inputStream().buffered().use { input ->
            val buffer = ByteArray(IO_BUFFER_BYTES)
            while (true) {
                val read = input.read(buffer)
                if (read < 0) break
                digest.update(buffer, 0, read)
            }
        }
        return digest.value
    }

    private fun validateIdentity(pluginId: String, version: String, format: String) {
        check(pluginId.matches(Regex("[a-z0-9][a-z0-9.-]{0,127}"))) { "invalid_request" }
        check(version.matches(Regex("\\d+\\.\\d+\\.\\d+(?:-[0-9A-Za-z.-]+)?"))) { "invalid_request" }
        check(format == "singleFile" || format == "archive") { "invalid_request" }
    }

    private companion object {
        const val MAX_ARTIFACT_BYTES = 32L * 1024L * 1024L
        const val MAX_TRANSFER_BATCH_BYTES = 512L * 1024L * 1024L
        const val IO_BUFFER_BYTES = 64 * 1024
        const val EXPORT_CHUNK_BYTES = 64 * 1024
    }
}

private fun artifactSuffix(format: String): String = when (format) {
    "singleFile" -> ".mgplugin.js"
    "archive" -> ".mgplugin"
    else -> error("invalid_request")
}
