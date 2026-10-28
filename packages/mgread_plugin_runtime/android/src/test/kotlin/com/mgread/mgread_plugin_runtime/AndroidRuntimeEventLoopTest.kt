package com.mgread.mgread_plugin_runtime

import java.util.concurrent.CountDownLatch
import java.util.concurrent.Semaphore
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicInteger
import org.junit.Assert.*
import org.junit.Test

class AndroidRuntimeEventLoopTest {
    @Test fun blockedNativeLoopWakesForCommandsAndShutdownOnItsOwner() {
        val entered = CountDownLatch(1)
        val delivered = CountDownLatch(1)
        val stopped = CountDownLatch(1)
        val signal = Semaphore(0)
        val failures = AtomicInteger()
        val loop = AndroidRuntimeEventLoop { failures.incrementAndGet() }
        var owner: Thread? = null
        loop.post {
            owner = Thread.currentThread()
            loop.setDriver({ block ->
                assertSame(owner, Thread.currentThread())
                if (block) { entered.countDown(); assertTrue(signal.tryAcquire(3, TimeUnit.SECONDS)) }
            }, { signal.release() })
        }
        assertTrue(entered.await(3, TimeUnit.SECONDS))
        assertTrue(loop.post { assertSame(owner, Thread.currentThread()); delivered.countDown() })
        assertTrue(delivered.await(3, TimeUnit.SECONDS))
        loop.post { loop.setDriver(null); loop.shutdown(); stopped.countDown() }
        assertTrue(stopped.await(3, TimeUnit.SECONDS))
        assertFalse(loop.post {})
        assertEquals(0, failures.get())
    }

    @Test fun pendingOperationDoesNotBlockAnotherQueuedCommand() {
        val submitted = CountDownLatch(1)
        val second = CountDownLatch(1)
        val reply = CountDownLatch(1)
        val loop = AndroidRuntimeEventLoop { fail("Owner queue failed") }
        loop.post { submitted.countDown() /* The operation's asynchronous result has not arrived. */ }
        loop.post { second.countDown() }
        assertTrue(submitted.await(3, TimeUnit.SECONDS))
        assertTrue(second.await(3, TimeUnit.SECONDS))
        loop.post { reply.countDown(); loop.shutdown() }
        assertTrue(reply.await(3, TimeUnit.SECONDS))
    }
}
