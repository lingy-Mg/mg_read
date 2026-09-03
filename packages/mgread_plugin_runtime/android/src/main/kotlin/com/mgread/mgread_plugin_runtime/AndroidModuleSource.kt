/**
 * Android Javet ESM source adapter.
 *
 * Responsibilities:
 * - initialize the standard module-relative `import.meta.url` from the owned file;
 * - adapt Cheerio's lone CommonJS boolbase leaf for the ESM-only resolver.
 *
 * Boundaries:
 * - accepts only files already validated by the caller's Runtime-owned roots;
 * - adds no leading line to ordinary ESM source, keeping stack lines stable.
 */
package com.mgread.mgread_plugin_runtime

import java.io.File

internal fun androidModuleSource(candidate: File): String {
    val source = if (candidate.isBoolbaseCommonJsLeaf()) {
        """
            const module = { exports: {} };
            const exports = module.exports;
            ${candidate.readText()}
            export default module.exports;
        """.trimIndent()
    } else {
        candidate.readText()
    }
    val moduleUrl = candidate.canonicalFile.toURI().toASCIIString()
    val initializer = "import.meta.url=\"$moduleUrl\";"
    if (!source.startsWith("#!")) return initializer + source

    val firstLineEnd = source.indexOf('\n')
    if (firstLineEnd < 0) return "$source\n$initializer"
    return source.substring(0, firstLineEnd + 1) +
        initializer +
        source.substring(firstLineEnd + 1)
}

private fun File.isBoolbaseCommonJsLeaf(): Boolean =
    path.replace(File.separatorChar, '/').endsWith("/node_modules/boolbase/index.js")
