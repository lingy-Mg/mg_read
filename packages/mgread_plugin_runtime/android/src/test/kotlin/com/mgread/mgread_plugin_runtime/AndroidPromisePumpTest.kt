package com.mgread.mgread_plugin_runtime

import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test

class AndroidPromisePumpTest {
    @Test
    fun completionDuringPumpReturnsWithoutSleeping() {
        var pending = true
        AndroidPromisePump.await(
            isPending = { pending },
            pump = { pending = false },
            sleep = { error("Completed promises must not incur a fixed delay") },
        )
    }

    @Test
    fun queuedWorkGetsOneExtraImmediateTurn() {
        var turns = 0
        AndroidPromisePump.await(
            isPending = { turns < 2 },
            pump = { turns++ },
            sleep = { error("A two-turn ready queue should not sleep") },
        )
        assertEquals(2, turns)
    }

    @Test
    fun slowIoBacksOffAndDoesNotBusySpin() {
        var elapsed = 0L
        var turns = 0
        val sleeps = mutableListOf<Long>()
        AndroidPromisePump.await(
            isPending = { elapsed < 200 },
            pump = { turns++ },
            sleep = { delay -> sleeps.add(delay); elapsed += delay },
        )
        assertTrue(sleeps.first() < 10)
        assertTrue(sleeps.all { it in 1L..10L })
        assertEquals(10L, sleeps.last())
        assertTrue("Waiting must be bounded rather than spinning", turns < 40)
    }

    @Test
    fun cancellationIsCheckedBetweenTurnsAndCompletesWithoutAnotherSleep() {
        var turns = 0
        var cancelled = false
        AndroidPromisePump.await(
            isPending = { !cancelled },
            beforePump = { if (turns == 2) cancelled = true },
            pump = { turns++ },
            sleep = { assertTrue("Only pre-cancellation waits are allowed", !cancelled) },
        )
        assertTrue(cancelled)
        assertEquals(3, turns)
    }
}
