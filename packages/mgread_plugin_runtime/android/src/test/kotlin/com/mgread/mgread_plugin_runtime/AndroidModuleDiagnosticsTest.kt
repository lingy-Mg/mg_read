/** Diagnostics must remain usable when Javet's exception formatting itself fails. */
package com.mgread.mgread_plugin_runtime

import org.junit.Assert.*
import org.junit.Test

class AndroidModuleDiagnosticsTest {
    private class UnformattableError : RuntimeException() {
        override val message: String get() = error("must_not_read_message")
        override fun toString(): String = error("must_not_format_exception")
    }

    @Test fun recordsModuleBeforeCompilationAndUsesOnlyTheErrorClass() {
        val events = mutableListOf<String>()
        val failure = runCatching {
            withAndroidModuleDiagnostics("./broken.js", "/core/desktop-runtime.js", events::add) {
                throw UnformattableError()
            }
        }.exceptionOrNull()
        assertTrue(failure is AndroidRuntimeError)
        assertEquals("runtime_module_compile_failed", (failure as AndroidRuntimeError).code)
        assertEquals(2, events.size)
        assertTrue(events.first().contains("resolve_started module=./broken.js"))
        assertTrue(events.last().contains("referrer=/core/desktop-runtime.js type=UnformattableError"))
    }

    @Test fun boundsLabelsAndEscapesNewlinesWithoutChangingModuleResolution() {
        val module = "a".repeat(600) + "\n"
        assertEquals(512, androidModuleLogLabel(module).length)
        assertEquals("a??b", androidModuleLogLabel("a\n\rb"))
        val events = mutableListOf<String>()
        assertEquals("ready", withAndroidModuleDiagnostics("entry.js", null, events::add) { "ready" })
        assertTrue(events.last().contains("resolve_complete"))
    }
}
