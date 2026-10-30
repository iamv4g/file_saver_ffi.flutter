package com.iamv4g.file_saver_ffi

import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/** A write session whose writes fail must not publish a truncated file. */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class WriteSessionTest : FileSaverTestBase() {
    @Test
    fun `close after a failed write reports the write error and deletes the row`() {
        mediaStore.readOnly = true
        val sessionId = openSession()

        val write = writeChunk(sessionId, byteArrayOf(1, 2, 3))
        assertEquals("Events: $write", 2, write.type)
        assertEquals(Constants.ERROR_FILE_IO, write.data)

        val close = RecordingCallback()
        fileSaver.closeSession(sessionId, close)
        val closed = close.awaitTerminal()

        assertEquals("Events: ${close.events}", 2, closed.type)
        assertEquals(write.data, closed.data)
        assertEquals(write.message, closed.message)
        assertTrue(mediaStore.rows.values.toString(), mediaStore.rows.isEmpty())
        assertNoCrash()
    }

    @Test
    fun `writes and flushes after a failed write report the same error`() {
        mediaStore.readOnly = true
        val sessionId = openSession()
        val failed = writeChunk(sessionId, byteArrayOf(1))
        assertEquals(2, failed.type)
        // A later write would succeed on its own; the session stays failed.
        mediaStore.readOnly = false

        val later = writeChunk(sessionId, byteArrayOf(2))
        val flush = RecordingCallback()
        fileSaver.flushSession(sessionId, flush)

        assertEquals(failed, later)
        assertEquals(failed, flush.awaitTerminal())
    }

    @Test
    fun `a session that never failed still publishes on close`() {
        val sessionId = openSession()
        assertEquals(1, writeChunk(sessionId, byteArrayOf(1, 2)).type)

        val close = RecordingCallback()
        fileSaver.closeSession(sessionId, close)

        assertEquals(3, close.awaitTerminal().type)
        assertEquals(1, mediaStore.rows.size)
    }

    private fun openSession(): Long {
        val open = RecordingCallback()
        openWriteSession("log", "txt", "text/plain", SaveLocation.DOWNLOADS, open)
        val opened = open.awaitTerminal()
        assertEquals("Events: ${open.events}", 3, opened.type)
        return opened.data!!.toLong()
    }

    /** Writes [data] and returns the chunk's single event (1 on success, 2 on error). */
    private fun writeChunk(
        sessionId: Long,
        data: ByteArray,
    ) = RecordingCallback().also { fileSaver.writeChunk(sessionId, data, it) }.awaitEvents(1)
}
