package com.iamv4g.file_saver_ffi

import android.net.Uri
import android.system.ErrnoException
import android.system.OsConstants
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.ErrorCode
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.ioErrorCode
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.IOException
import java.io.OutputStream

/**
 * The error code and message the Dart side receives: the code picks the Dart
 * exception, and the message is only the detail it needs (see
 * `FileSaverErrorCode` in Dart).
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ErrorReportingTest : FileSaverTestBase() {
    private fun outOfSpace() = IOException("write failed: ENOSPC (No space left on device)", ErrnoException("write", OsConstants.ENOSPC))

    /** Makes every write to the first MediaStore row throw [error]. */
    private fun failWrites(error: IOException) {
        // The fake numbers rows from 1, so the first insert gets this URI.
        shadowOf(context.contentResolver).registerOutputStream(
            Uri.parse("content://media/external_primary/downloads/1"),
            object : OutputStream() {
                override fun write(b: Int) = throw error

                override fun write(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ) = throw error
            },
        )
    }

    @Test
    fun `an out-of-space error is STORAGE_FULL, any other IOException FILE_IO_ERROR`() {
        assertEquals(ErrorCode.STORAGE_FULL, ioErrorCode(outOfSpace()))
        assertEquals(ErrorCode.STORAGE_FULL, ioErrorCode(IOException(ErrnoException("write", OsConstants.EDQUOT))))
        // A provider that keeps only the text.
        assertEquals(ErrorCode.STORAGE_FULL, ioErrorCode(IOException("write failed: ENOSPC (No space left on device)")))
        assertEquals(ErrorCode.FILE_IO_ERROR, ioErrorCode(IOException("write failed: EIO (I/O error)", ErrnoException("write", OsConstants.EIO))))
        assertEquals(ErrorCode.FILE_IO_ERROR, ioErrorCode(IOException()))
    }

    @Test
    fun `a save that runs out of space reports STORAGE_FULL and removes the new row`() {
        failWrites(outOfSpace())

        val callback = saveBytes(byteArrayOf(1, 2, 3), "data", "bin", "application/octet-stream", SaveLocation.DOWNLOADS)

        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(ErrorCode.STORAGE_FULL, event.data)
        assertTrue(mediaStore.rows.isEmpty())
        assertNoCrash()
    }

    @Test
    fun `a write session that runs out of space reports STORAGE_FULL`() {
        failWrites(outOfSpace())
        val open = RecordingCallback()
        openWriteSession("data", "bin", "application/octet-stream", SaveLocation.DOWNLOADS, open)
        val sessionId = open.awaitTerminal().data!!.toLong()

        val write = RecordingCallback()
        fileSaver.writeChunk(sessionId, byteArrayOf(1, 2, 3), write)

        val event = write.awaitTerminal()
        assertEquals("Events: ${write.events}", 2, event.type)
        assertEquals(ErrorCode.STORAGE_FULL, event.data)
        assertNoCrash()
    }

    @Test
    fun `FILE_EXISTS carries just the file name`() {
        saveBytes(byteArrayOf(1), "taken", "bin", "application/octet-stream", SaveLocation.DOWNLOADS)

        val callback =
            saveBytes(
                byteArrayOf(2),
                "taken",
                "bin",
                "application/octet-stream",
                SaveLocation.DOWNLOADS,
                conflictResolution = ConflictResolution.FAIL,
            )

        val event = callback.awaitTerminal()
        assertEquals(ErrorCode.FILE_EXISTS, event.data)
        assertEquals("taken.bin", event.message)
    }

    @Test
    fun `FILE_NOT_FOUND carries just the source path`() {
        val source = "/no/such/file.bin"
        val callback = RecordingCallback()

        fileSaver.saveFile(
            source,
            "copy",
            "bin",
            "application/octet-stream",
            SaveLocation.DOWNLOADS.ordinal,
            null,
            ConflictResolution.AUTO_RENAME.ordinal,
            callback,
        )

        val event = callback.awaitTerminal()
        assertEquals(ErrorCode.FILE_NOT_FOUND, event.data)
        assertEquals(source, event.message)
    }
}
