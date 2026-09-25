package com.mgread.mgread_plugin_runtime

import java.io.File
import java.nio.file.Files
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidNodeLaunchContractTest {
    @Test
    fun acceptsOnlyThePrivateCliAndDataRoot() {
        val root = Files.createTempDirectory("mgread-node-launch").toFile()
        try {
            val entrypoint = File(root, "dist/cli.js")
            entrypoint.parentFile.mkdirs()
            entrypoint.writeText("// test")
            val data = File(root, "private-data")
            val valid = listOf(
                "node", entrypoint.path,
                "--data-root=${data.path}", "--debug-http-enabled=1",
            )
            assertTrue(AndroidNodeLaunchContract.isValid(valid, root, data))
            assertFalse(AndroidNodeLaunchContract.isValid(valid + "--inspect", root, data))
            assertFalse(AndroidNodeLaunchContract.isValid(valid.toMutableList().also {
                it[1] = File(root, "other.js").path
            }, root, data))
            assertFalse(AndroidNodeLaunchContract.isValid(valid.toMutableList().also {
                it[2] = "--data-root=/tmp/external"
            }, root, data))
            entrypoint.delete()
            assertFalse(AndroidNodeLaunchContract.isValid(valid, root, data))
        } finally {
            root.deleteRecursively()
        }
    }
}
