package com.vanvixi.file_saver_ffi

import android.Manifest
import android.net.Uri
import android.os.Environment
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.SaveLocation
import com.vanvixi.file_saver_ffi.testing.FakeMediaStoreProvider
import com.vanvixi.file_saver_ffi.testing.FileSaverTestBase
import com.vanvixi.file_saver_ffi.testing.RecordingCallback
import com.vanvixi.file_saver_ffi.utils.Constants
import kotlinx.coroutines.CompletableDeferred
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/**
 * Drives [FileSaver] through the same entry points the Dart side calls over
 * JNI, against [FakeMediaStoreProvider] on Android 10+ and the Robolectric
 * external storage directory on Android 9.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FileSaverTest : FileSaverTestBase() {
    // ── write sessions ──────────────────────────────────────────────────────

    @Test
    fun `openWriteSession reports INVALID_INPUT for a location the file type can't go to, without crashing`() {
        val callback = RecordingCallback()

        // MediaProvider only accepts images in Pictures/ and DCIM/.
        openWriteSession("photo", "png", "image/png", SaveLocation.MOVIES, callback)

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertTrue(event.message!!.contains("image/png"))
        assertTrue(mediaStore.rows.isEmpty())
        assertNoCrash()
    }

    @Test
    fun `openWriteSessionAs reports INVALID_INPUT for a URI that is not a directory tree, without crashing`() {
        val callback = RecordingCallback()

        fileSaver.openWriteSessionAs(
            "content://com.android.externalstorage.documents/document/primary%3ADownload",
            "photo",
            "png",
            "image/png",
            ConflictResolution.AUTO_RENAME.value,
            -1,
            callback,
        )

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertNoCrash()
    }

    @Test
    fun `a write session streams chunks into a MediaStore row and publishes it on close`() {
        val open = RecordingCallback()
        openWriteSession("photo", "png", "image/png", SaveLocation.PICTURES, open)
        val opened = open.awaitTerminal()
        assertEquals(3, opened.type)
        val sessionId = opened.data!!.toLong()

        val chunks = RecordingCallback()
        fileSaver.writeChunk(sessionId, byteArrayOf(1, 2, 3), chunks)
        fileSaver.writeChunk(sessionId, byteArrayOf(4, 5), chunks)
        assertEquals(5.0, chunks.awaitEvents(2).progress, 0.0)

        val close = RecordingCallback()
        fileSaver.closeSession(sessionId, close)
        val closed = close.awaitTerminal()
        assertEquals(3, closed.type)

        val row = mediaStore.rowNamed("photo.png")!!
        assertEquals("content://media/external_primary/images/media/${row.id}", closed.data)
        assertEquals("Pictures/probe/", row.relativePath)
        assertFalse(row.isPending)
        assertArrayEquals(byteArrayOf(1, 2, 3, 4, 5), row.file.readBytes())
        assertNoCrash()
    }

    @Test
    fun `cancelSession deletes the pending row`() {
        val open = RecordingCallback()
        openWriteSession("photo", "png", "image/png", SaveLocation.PICTURES, open)
        val sessionId = open.awaitTerminal().data!!.toLong()
        assertEquals(1, mediaStore.rows.size)

        fileSaver.cancelSession(sessionId)

        val deadline = System.currentTimeMillis() + 5_000
        while (mediaStore.rows.isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(10)
        assertTrue(mediaStore.rows.isEmpty())
    }

    // ── one-shot saves ─────────────────────────────────────────────────────

    @Test
    fun `saveBytes reports progress and completes with the new row`() {
        val callback = RecordingCallback()
        val data = ByteArray(3 * Constants.CHUNK_SIZE) { it.toByte() }

        fileSaver.saveBytes(data, "photo", "png", "image/png", SaveLocation.PICTURES.ordinal, null, ConflictResolution.AUTO_RENAME.value, callback)

        val event = callback.awaitTerminal()
        assertEquals(3, event.type)
        assertEquals(0, callback.events.first().type)
        assertTrue(callback.events.count { it.type == 1 } >= 3)
        assertArrayEquals(data, mediaStore.rowNamed("photo.png")!!.file.readBytes())
    }

    @Test
    fun `saveBytes to a location the file type can't go to ends with an error event`() {
        val callback = saveBytes(byteArrayOf(1), "photo", "png", "image/png", SaveLocation.MOVIES)

        assertEquals(2, callback.awaitTerminal().type)
        assertNoCrash()
    }

    @Test
    fun `a callback that throws does not crash the app`() {
        // The Dart side going away mid-save can make the JNI callback throw.
        val callback = RecordingCallback { if (it.type == 0) throw IllegalStateException("isolate gone") }

        fileSaver.saveBytes(byteArrayOf(1, 2, 3), "photo", "png", "image/png", SaveLocation.PICTURES.ordinal, null, ConflictResolution.AUTO_RENAME.value, callback)

        Thread.sleep(500)
        assertNoCrash()
    }

    // ── Android 9 and below ────────────────────────────────────────────────

    @Test
    @Config(sdk = [28])
    fun `a write session on Android 9 writes a plain file in the public directory`() {
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val open = RecordingCallback()
        openWriteSession("photo", "png", "image/png", SaveLocation.PICTURES, open)
        val sessionId = open.awaitTerminal().data!!.toLong()

        fileSaver.writeChunk(sessionId, byteArrayOf(7, 8, 9), RecordingCallback())
        val close = RecordingCallback()
        fileSaver.closeSession(sessionId, close)
        val closed = close.awaitTerminal()

        assertEquals(3, closed.type)
        val file = File(Uri.parse(closed.data).path!!)
        assertEquals(File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_PICTURES), "probe/photo.png"), file)
        assertArrayEquals(byteArrayOf(7, 8, 9), file.readBytes())
    }

    @Test
    @Config(sdk = [28])
    fun `cancelling while the storage permission prompt is open reports no error`() {
        shadowOf(context).denyPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val prompt = CompletableDeferred<Boolean>()
        FileSaver.storagePermissionHandler = { prompt.await() }
        val callback = RecordingCallback()

        val operationId =
            fileSaver.saveBytes(byteArrayOf(1), "photo", "png", "image/png", SaveLocation.PICTURES.ordinal, null, ConflictResolution.AUTO_RENAME.value, callback)
        Thread.sleep(200)
        fileSaver.cancelOperation(operationId)
        Thread.sleep(300)

        assertTrue("Events: ${callback.events}", callback.events.none { it.type == 2 })
        assertNoCrash()
    }
}
