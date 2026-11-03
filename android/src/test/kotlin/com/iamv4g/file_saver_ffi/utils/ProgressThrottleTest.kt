package com.iamv4g.file_saver_ffi.utils

import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test

class ProgressThrottleTest {
    private var now = 1_000L

    private fun throttle(totalBytes: Long?) = ProgressThrottle(totalBytes) { now }

    @Test
    fun `reports the first count, then steps of at least 1 percent`() {
        val throttle = throttle(10_000)

        assertTrue(throttle.shouldReport(10))
        assertFalse(throttle.shouldReport(50))
        assertFalse(throttle.shouldReport(109))
        assertTrue(throttle.shouldReport(110))
        assertFalse(throttle.shouldReport(150))
    }

    @Test
    fun `reports a smaller step once 100 ms have passed`() {
        val throttle = throttle(10_000)
        assertTrue(throttle.shouldReport(10))

        now += 99
        assertFalse(throttle.shouldReport(20))
        now += 1
        assertTrue(throttle.shouldReport(20))
    }

    @Test
    fun `reports the total and the last count, but nothing twice`() {
        val throttle = throttle(10_000)
        assertTrue(throttle.shouldReport(10))

        assertTrue(throttle.shouldReport(10_000))
        assertFalse(throttle.shouldReport(10_000, isLast = true))
    }

    @Test
    fun `an unknown size reports every 100 ms and the last count`() {
        val throttle = throttle(null)
        val reported = mutableListOf<Long>()

        for (bytes in 1L..1_000L) {
            if (bytes % 10 == 0L) now += 5
            if (throttle.shouldReport(bytes, isLast = bytes == 1_000L)) reported += bytes
        }

        // 1, then one count for each 100 ms (every 200 bytes here), and 1000.
        assertEquals(listOf(1L, 200L, 400L, 600L, 800L, 1_000L), reported)
    }

    @Test
    fun `nothing written reports nothing`() {
        assertFalse(throttle(null).shouldReport(0, isLast = true))
    }
}
