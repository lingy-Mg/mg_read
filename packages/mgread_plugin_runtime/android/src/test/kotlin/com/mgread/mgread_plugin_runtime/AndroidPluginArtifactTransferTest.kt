/** Byte-bounded staging and whole-batch validation without a device or VM. */
package com.mgread.mgread_plugin_runtime

import java.nio.file.Files
import java.io.File
import java.util.zip.CRC32
import org.junit.Assert.*
import org.junit.Test

class AndroidPluginArtifactTransferTest {
    @Test
    fun stages65SourcesBeforePublishingOneBatch() {
        withTransfer { root, transfer ->
            val bytes = "single-js-fixture".toByteArray()
            val ids = (0 until 65).map { index ->
                val session = transfer.beginImport("org.test.$index", "1.0.0", bytes.size.toLong(), checksum(bytes), "singleFile")
                File(session.getValue("temporaryPath")).writeBytes(bytes)
                session.getValue("id")
            }
            assertEquals(65, root.listFiles()!!.count { it.name.endsWith(".part") })
            transfer.finishImportBatch(ids)
            assertEquals(65, root.listFiles()!!.count { it.name.endsWith(".mgplugin.js") })
            assertTrue(root.listFiles()!!.all { it.readBytes().contentEquals(bytes) })
        }
    }

    @Test
    fun corruptLastFileDoesNotPublishEarlierFiles() {
        withTransfer { root, transfer ->
            val bytes = "fixture".toByteArray()
            val firstSession = transfer.beginImport("org.test.a", "1.0.0", bytes.size.toLong(), checksum(bytes), "singleFile")
            val lastSession = transfer.beginImport("org.test.b", "1.0.0", bytes.size.toLong(), "00000000", "singleFile")
            File(firstSession.getValue("temporaryPath")).writeBytes(bytes)
            File(lastSession.getValue("temporaryPath")).writeBytes(bytes)
            val first = firstSession.getValue("id")
            val last = lastSession.getValue("id")
            assertEquals("plugin_transfer_checksum_mismatch", runCatching {
                transfer.finishImportBatch(listOf(first, last))
            }.exceptionOrNull()?.message)
            assertTrue(root.listFiles()!!.all { it.name.endsWith(".part") })
            transfer.cancelImports(listOf(first, last))
            assertEquals(0, root.listFiles()!!.size)
        }
    }

    @Test
    fun enforcesAggregateBytesAndReleasesCanceledBudget() {
        withTransfer { _, transfer ->
            val ids = (0 until 16).map {
                transfer.beginImport("org.test.$it", "1.0.0", 32L * 1024 * 1024, "00000000", "singleFile").getValue("id")
            }
            assertEquals("transfer_batch_too_large", runCatching {
                transfer.beginImport("org.test.excess", "1.0.0", 1, "00000000", "singleFile")
            }.exceptionOrNull()?.message)
            transfer.cancelImports(ids)
            val next = transfer.beginImport("org.test.next", "1.0.0", 1, "00000000", "singleFile").getValue("id")
            transfer.cancelImports(listOf(next))
        }
    }

    private fun checksum(bytes: ByteArray) = CRC32().apply { update(bytes) }.value.toString(16).padStart(8, '0')

    private fun withTransfer(test: (java.io.File, AndroidPluginArtifactTransfer) -> Unit) {
        val root = Files.createTempDirectory("mgread-transfer").toFile()
        try { test(root, AndroidPluginArtifactTransfer(root)) }
        finally { root.deleteRecursively() }
    }
}
