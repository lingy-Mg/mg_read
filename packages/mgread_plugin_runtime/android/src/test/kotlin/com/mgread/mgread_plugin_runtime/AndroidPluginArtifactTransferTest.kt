/** Byte-bounded whole-directory publication, corruption and interrupted-host recovery. */
package com.mgread.mgread_plugin_runtime

import java.nio.file.Files
import java.io.File
import java.util.zip.CRC32
import org.junit.Assert.*
import org.junit.Test

class AndroidPluginArtifactTransferTest {
    @Test fun stages65SourcesBeforeOneDirectoryPublication() = withTransfer { root, transfer ->
        val bytes = "fixture".toByteArray()
        val batch = transfer.beginImportBatch((0 until 65).map { metadata(it, bytes) })
        writeBatch(batch, List(65) { bytes })
        assertEquals(1, root.listFiles()!!.size)
        assertTrue(root.listFiles()!!.single().name.endsWith(".part"))
        transfer.finishImportBatch(batch["id"] as String)
        val published = root.listFiles()!!.single()
        assertTrue(published.name.startsWith("batch-"))
        assertEquals(65, published.listFiles()!!.count { it.name.endsWith(".mgplugin.js") })
        AndroidPluginArtifactTransfer(root)
        assertTrue(published.exists())
    }

    @Test fun corruptLastFilePublishesNothing() = withTransfer { root, transfer ->
        val bytes = "fixture".toByteArray()
        val batch = transfer.beginImportBatch(listOf(metadata(0, bytes), metadata(1, bytes) + ("checksum" to "00000000")))
        writeBatch(batch, listOf(bytes, bytes))
        assertEquals("plugin_transfer_checksum_mismatch", runCatching {
            transfer.finishImportBatch(batch["id"] as String)
        }.exceptionOrNull()?.message)
        assertTrue(root.listFiles()!!.all { it.name.endsWith(".part") })
        transfer.cancelImportBatch(batch["id"] as String)
        assertEquals(0, root.listFiles()!!.size)
    }

    @Test fun truncatedFilePublishesNothing() = withTransfer { _, transfer ->
        val bytes = "fixture".toByteArray()
        val batch = transfer.beginImportBatch(listOf(metadata(0, bytes)))
        writeBatch(batch, listOf(byteArrayOf(1)))
        assertEquals("plugin_transfer_size_mismatch", runCatching {
            transfer.finishImportBatch(batch["id"] as String)
        }.exceptionOrNull()?.message)
    }

    @Test fun rejectsOversizedBatchBeforeAllocatingAndReleasesCanceledBatch() = withTransfer { root, transfer ->
        val large = (0 until 17).map { metadata(it, byteArrayOf(1)) + ("bytes" to 32L * 1024 * 1024) }
        assertEquals("transfer_batch_too_large", runCatching { transfer.beginImportBatch(large) }.exceptionOrNull()?.message)
        assertEquals(0, root.listFiles()!!.size)
        val next = transfer.beginImportBatch(listOf(metadata(0, byteArrayOf(1))))
        assertEquals("invalid_request", runCatching { transfer.beginImportBatch(listOf(metadata(1, byteArrayOf(1)))) }.exceptionOrNull()?.message)
        transfer.cancelImportBatch(next["id"] as String)
        transfer.beginImportBatch(listOf(metadata(1, byteArrayOf(1))))
    }

    @Test fun hostRecreationCleansOnlyUnpublishedStaging() = withTransfer { root, transfer ->
        val bytes = "fixture".toByteArray()
        val batch = transfer.beginImportBatch(listOf(metadata(0, bytes)))
        writeBatch(batch, listOf(bytes))
        val unrelated = File(root, "keep.txt").apply { writeText("keep") }
        AndroidPluginArtifactTransfer(root)
        assertEquals(listOf(unrelated.name), root.listFiles()!!.map { it.name })
    }

    @Test fun rejectsPathIdentityAndInvalidCancelId() = withTransfer { _, transfer ->
        assertEquals("invalid_request", runCatching {
            transfer.beginImportBatch(listOf(metadata(0, byteArrayOf(1)) + ("id" to "../escape")))
        }.exceptionOrNull()?.message)
        assertEquals("invalid_request", runCatching { transfer.cancelImportBatch("../escape") }.exceptionOrNull()?.message)
    }

    @Test fun rejectsLowDiskBeforeCreatingStaging() = withTransfer { root, _ ->
        val transfer = AndroidPluginArtifactTransfer(root) { 0L }
        assertEquals("disk_full", runCatching { transfer.beginImportBatch(listOf(metadata(0, byteArrayOf(1)))) }.exceptionOrNull()?.message)
        assertEquals(0, root.listFiles()!!.size)
    }

    private fun metadata(index: Int, bytes: ByteArray): Map<String, Any?> = mapOf(
        "id" to "org.test.$index", "version" to "1.0.0", "format" to "singleFile",
        "bytes" to bytes.size.toLong(), "checksum" to CRC32().apply { update(bytes) }.value.toString(16).padStart(8, '0'),
    )
    private fun writeBatch(batch: Map<String, Any?>, files: List<ByteArray>) {
        @Suppress("UNCHECKED_CAST") val paths = batch["temporaryPaths"] as List<String>
        paths.forEachIndexed { index, path -> File(path).writeBytes(files[index]) }
        File(batch["directory"] as String, "manifest.json").writeText("{}")
    }
    private fun withTransfer(test: (File, AndroidPluginArtifactTransfer) -> Unit) {
        val root = Files.createTempDirectory("mgread-transfer").toFile()
        try { test(root, AndroidPluginArtifactTransfer(root)) }
        finally { root.deleteRecursively() }
    }
}
