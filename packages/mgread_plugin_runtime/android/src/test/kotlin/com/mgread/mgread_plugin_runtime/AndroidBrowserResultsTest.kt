package com.mgread.mgread_plugin_runtime

import java.util.concurrent.CountDownLatch
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class AndroidBrowserResultsTest {
    @Test fun completionBeforeRegistrationIsDeliveredOnce() {
        val results = AndroidBrowserResults()
        results.complete("one", "reply")
        val received = mutableListOf<String>()
        results.listen("one") { received += it; results.forget("one") }
        assertEquals(listOf("reply"), received)
        assertNull(results.take("one"))
    }

    @Test fun concurrentCompletionAndRegistrationDoNotLoseReplies() {
        repeat(100) {
            val results = AndroidBrowserResults()
            val gate = CountDownLatch(1)
            val received = AtomicInteger()
            val register = Thread { gate.await(); results.listen("one") { received.incrementAndGet() } }
            val complete = Thread { gate.await(); results.complete("one", "reply") }
            register.start(); complete.start(); gate.countDown()
            register.join(3000); complete.join(3000)
            assertFalse(register.isAlive || complete.isAlive)
            assertEquals(1, received.get())
            assertNull(results.take("one"))
        }
    }

    @Test fun abandonedVmCannotReceiveOrRetainALateBrowserReply() {
        val results = AndroidBrowserResults()
        results.listen("one") { fail("Old VM must not receive a late result") }
        results.forget("one")
        results.complete("one", "late reply")
        assertNull(results.take("one"))
    }
}
