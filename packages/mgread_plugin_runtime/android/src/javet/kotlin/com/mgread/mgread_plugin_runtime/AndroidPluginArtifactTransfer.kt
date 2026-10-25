/**
 * Android plugin artifact transfer and Runtime inbox IO.
 *
 * Owns Android-private staging paths, artifact metadata and import/export
 * sessions. Dart writes imports to the returned .part paths; this class checks
 * the completed files and publishes the full batch before one Core restart.
 * Whole batches publish with one directory rename; host construction cleans
 * abandoned staging. Each host calls this from its serial IO thread.
 */
package com.mgread.mgread_plugin_runtime

import android.content.Context
import java.io.File
import java.io.FileInputStream
import java.util.UUID
import java.util.zip.CRC32

internal class AndroidPluginArtifactTransfer(
    private val inboxDirectory: File,
    private val availableBytes: () -> Long = { inboxDirectory.usableSpace },
) {
    constructor(context: Context) : this(sharedPluginImportInbox(context))

    private data class ImportFile(val temporary: File, val target: File, val bytes: Long, val checksum: String)
    private data class ImportBatch(val id: String, val directory: File, val files: List<ImportFile>)
    private data class ExportSession(val input: FileInputStream)
    private var activeBatch: ImportBatch? = null
    private val exportSessions = mutableMapOf<String, ExportSession>()

    init {
        // Host construction is the only orphan cleanup point. Core restarts
        // must never remove a batch that Dart is still writing.
        inboxDirectory.mkdirs()
        inboxDirectory.canonicalFile.listFiles()?.filter {
            it.name.matches(Regex("\\.batch-[a-f0-9]{32}\\.part")) ||
                it.name.matches(Regex("(?:transfer-|import-).+\\.mgplugin(?:\\.js)?\\.part"))
        }?.forEach(::deletePrivate)
    }

    fun beginImportBatch(artifacts: List<Map<String, Any?>>): Map<String, Any?> {
        check(activeBatch == null && artifacts.isNotEmpty()) { "invalid_request" }
        val ids = mutableSetOf<String>()
        var total = 0L
        val metadata = artifacts.map { artifact ->
            val pluginId = artifact["id"] as? String ?: error("invalid_request")
            val version = artifact["version"] as? String ?: error("invalid_request")
            val format = artifact["format"] as? String ?: error("invalid_request")
            validateIdentity(pluginId, version, format)
            check(ids.add(pluginId)) { "invalid_request" }
            val bytes = (artifact["bytes"] as? Number)?.toLong() ?: error("invalid_request")
            val checksum = artifact["checksum"] as? String ?: error("invalid_request")
            check(bytes in 1..MAX_ARTIFACT_BYTES) { "file_too_large" }
            check(checksum.matches(Regex("[a-f0-9]{8}"))) { "invalid_request" }
            total += bytes
            check(total <= MAX_TRANSFER_BATCH_BYTES) { "transfer_batch_too_large" }
            Triple(bytes, checksum, format)
        }
        val reserve = if (metadata.any { it.third == "archive" }) 256L * 1024 * 1024 else 4L * 1024 * 1024
        check(availableBytes() >= total * 3 + reserve) { "disk_full" }
        val id = UUID.randomUUID().toString().replace("-", "")
        val directory = File(inboxDirectory, ".batch-$id.part")
        check(directory.mkdir()) { "disk_full" }
        val files = metadata.mapIndexed { index, (bytes, checksum, format) ->
            val target = File(directory, "$index${artifactSuffix(format)}")
            ImportFile(File(target.path + ".part"), target, bytes, checksum)
        }
        activeBatch = ImportBatch(id, directory, files)
        return mapOf("id" to id, "directory" to directory.absolutePath,
            "temporaryPaths" to files.map { it.temporary.absolutePath })
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

    fun finishImportBatch(id: String) {
        val batch = activeBatch?.takeIf { it.id == id } ?: error("invalid_request")
        check(File(batch.directory, "manifest.json").isFile) { "invalid_request" }
        batch.files.forEach { file ->
            check(file.temporary.isFile && file.temporary.length() == file.bytes) { "plugin_transfer_size_mismatch" }
            check(checksum(file.temporary).toString(16).padStart(8, '0') == file.checksum) { "plugin_transfer_checksum_mismatch" }
        }
        try {
            batch.files.forEach { check(it.temporary.renameTo(it.target)) { "disk_full" } }
            // Only this one directory rename exposes the complete batch to Core.
            check(batch.directory.renameTo(File(inboxDirectory, "batch-$id"))) { "disk_full" }
            activeBatch = null
        } catch (error: Throwable) {
            runCatching { cancelImportBatch(id) }
            throw error
        }
    }

    fun cancelImportBatch(id: String) {
        check(id.matches(Regex("[a-f0-9]{32}"))) { "invalid_request" }
        if (activeBatch?.id == id) activeBatch = null
        deletePrivate(File(inboxDirectory, ".batch-$id.part"))
        deletePrivate(File(inboxDirectory, "batch-$id"))
    }

    fun dispose() {
        activeBatch?.let { runCatching { cancelImportBatch(it.id) } }
        exportSessions.values.forEach { runCatching { it.input.close() } }
        exportSessions.clear()
    }

    private fun deletePrivate(file: File) {
        if (!file.exists()) return
        // Do not follow a plugin-created symlink, including one inside a batch.
        val owner = inboxDirectory.canonicalFile
        val absolute = File(requireNotNull(file.parentFile).canonicalFile, file.name).normalize()
        if (file.canonicalFile != absolute) {
            check(file.delete()) { "file_write_failed" }
            return
        }
        check(absolute.path.startsWith(owner.path + File.separator)) { "invalid_request" }
        if (file.isDirectory) file.listFiles()?.forEach(::deletePrivate)
        check(file.delete()) { "file_write_failed" }
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

/** Migrates Javet's former inbox before either backend opens its shared data root. */
private fun sharedPluginImportInbox(context: Context): File {
    val root = File(context.filesDir, "mgread-runtime").canonicalFile
    val inbox = File(root, "data/import-inbox").apply { mkdirs() }
    val legacy = File(root, "import-inbox")
    if (legacy.isDirectory && legacy.canonicalFile == legacy) {
        AndroidPluginArtifactTransfer(legacy) // Reclaim only abandoned .part entries.
        legacy.listFiles()?.filter {
            it.isFile && it.canonicalFile == it &&
                it.name.matches(Regex("[a-zA-Z0-9._-]+\\.mgplugin(?:\\.js)?"))
        }?.forEach { file ->
            val suffix = if (file.name.endsWith(".js")) ".mgplugin.js" else ".mgplugin"
            check(file.renameTo(File(inbox, "import-${UUID.randomUUID()}$suffix"))) { "file_write_failed" }
        }
    }
    return inbox.canonicalFile
}
