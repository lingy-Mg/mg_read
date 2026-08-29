package com.mgread.mgread_plugin_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Rule
import org.junit.Test
import org.junit.rules.TemporaryFolder
import java.io.File

class AndroidModuleSourceTest {
    @get:Rule
    val temporaryFolder = TemporaryFolder()

    @Test
    fun initializesImportMetaUrlFromCanonicalModuleFileWithoutShiftingLines() {
        val module = temporaryFolder.newFile("entry module.js")
        val original = "export const asset = new URL('./asset.css', import.meta.url);\n"
        module.writeText(original)

        val source = androidModuleSource(module)

        assertTrue(
            source.startsWith(
                "import.meta.url=\"${module.canonicalFile.toURI().toASCIIString()}\";",
            ),
        )
        assertTrue(source.endsWith(original))
        assertEquals(original.count { it == '\n' }, source.count { it == '\n' })
    }

    @Test
    fun preservesHashbangAsTheFirstLine() {
        val module = temporaryFolder.newFile("command.mjs")
        module.writeText("#!/usr/bin/env node\nexport const value = import.meta.url;\n")

        val source = androidModuleSource(module)

        assertTrue(source.startsWith("#!/usr/bin/env node\nimport.meta.url="))
        assertEquals(2, source.count { it == '\n' })
    }

    @Test
    fun retainsTheBoolbaseCommonJsAdapter() {
        val boolbase = File(
            temporaryFolder.root,
            "node_modules/boolbase/index.js",
        ).apply {
            requireNotNull(parentFile).mkdirs()
            writeText("module.exports = function fixture() { return true; };\n")
        }

        val source = androidModuleSource(boolbase)

        assertTrue(source.contains("const module = { exports: {} };"))
        assertTrue(source.contains("module.exports = function fixture()"))
        assertTrue(source.contains("export default module.exports;"))
    }
}
