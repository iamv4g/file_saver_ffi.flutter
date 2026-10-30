package com.iamv4g.file_saver_ffi.utils

import com.iamv4g.file_saver_ffi.core.base.sendError
import com.iamv4g.file_saver_ffi.core.base.sendProgress
import com.iamv4g.file_saver_ffi.core.base.sendSuccess
import com.iamv4g.file_saver_ffi.models.SaveProgressEvent
import kotlinx.coroutines.delay
import kotlinx.coroutines.flow.toList
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertEquals
import org.junit.Test

class SaveFlowBuilderTest {
    /** Collects [flow] while pausing on every event, so the producer fills the channel buffer. */
    private fun slowCollect(flow: kotlinx.coroutines.flow.Flow<SaveProgressEvent>): List<SaveProgressEvent> =
        runBlocking {
            val events = mutableListOf<SaveProgressEvent>()
            flow.collect {
                events += it
                if (events.size == 1) delay(200)
            }
            events
        }

    @Test
    fun `starts with Started`() {
        val events = runBlocking { saveFlow { sendSuccess("content://x") }.toList() }

        assertEquals(listOf(SaveProgressEvent.Started, SaveProgressEvent.Success("content://x")), events)
    }

    @Test
    fun `Success is not dropped when progress overflows the buffer`() {
        val events =
            slowCollect(
                saveFlow {
                    repeat(500) { sendProgress(it / 500.0) }
                    sendSuccess("content://media/1")
                },
            )

        assertEquals(SaveProgressEvent.Success("content://media/1"), events.last())
    }

    @Test
    fun `Error is not dropped when progress overflows the buffer`() {
        val events =
            slowCollect(
                saveFlow {
                    repeat(500) { sendProgress(it / 500.0) }
                    sendError(Constants.ERROR_FILE_IO, "disk full")
                },
            )

        assertEquals(SaveProgressEvent.Error(Constants.ERROR_FILE_IO, "disk full"), events.last())
    }

    @Test
    fun `an exception thrown by the block after a progress flood still ends the flow with an Error`() {
        val events =
            slowCollect(
                saveFlow {
                    repeat(500) { sendProgress(it / 500.0) }
                    throw IllegalStateException("boom")
                },
            )

        assertEquals(SaveProgressEvent.Error(Constants.ERROR_PLATFORM, "Unexpected error: boom"), events.last())
    }

    @Test
    fun `SecurityException maps to PERMISSION_DENIED`() {
        val events = runBlocking { saveFlow { throw SecurityException("revoked") }.toList() }

        assertEquals(SaveProgressEvent.Error(Constants.ERROR_PERMISSION_DENIED, "Permission denied: revoked"), events.last())
    }
}
