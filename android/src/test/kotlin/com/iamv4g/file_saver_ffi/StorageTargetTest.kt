package com.iamv4g.file_saver_ffi

import android.Manifest
import android.net.Uri
import android.os.Environment
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.io.OutputStream

/**
 * Where a save lands: the MediaStore collection and directory on Android 10+,
 * the public directory on Android 9, and what is left behind when it fails.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class StorageTargetTest : FileSaverTestBase() {
    private fun assertSavedTo(
        callback: RecordingCallback,
        collection: String,
        relativePath: String,
    ) {
        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 3, event.type)
        val row = mediaStore.rows.values.single()
        assertEquals(collection, row.collection)
        assertEquals(relativePath, row.relativePath)
        assertTrue(event.data!!.startsWith("content://media/external_primary/$collection/"))
    }

    private fun assertInvalidInput(
        callback: RecordingCallback,
        messageContains: String,
    ) {
        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertTrue(event.message, event.message!!.contains(messageContains))
        assertTrue(mediaStore.rows.isEmpty())
    }

    // ── collection follows the MIME type ───────────────────────────────────

    @Test
    fun `a video saved to DCIM goes to the Video collection`() {
        assertSavedTo(saveBytes(byteArrayOf(1), "clip", "mp4", "video/mp4", SaveLocation.DCIM), "video", "DCIM/probe/")
    }

    @Test
    fun `a video saved to Pictures goes to the Video collection`() {
        assertSavedTo(saveBytes(byteArrayOf(1), "clip", "mp4", "video/mp4", SaveLocation.PICTURES), "video", "Pictures/probe/")
    }

    @Test
    @Config(sdk = [29])
    fun `a video saved to Pictures on Android 10, which rejects it, is reported as INVALID_INPUT`() {
        assertInvalidInput(saveBytes(byteArrayOf(1), "clip", "mp4", "video/mp4", SaveLocation.PICTURES), "video/mp4 to Pictures/")
    }

    @Test
    fun `an image saved to DCIM goes to the Images collection`() {
        assertSavedTo(saveBytes(byteArrayOf(1), "photo", "jpg", "image/jpeg", SaveLocation.DCIM), "images", "DCIM/probe/")
    }

    @Test
    fun `audio saved to Music goes to the Audio collection`() {
        assertSavedTo(saveBytes(byteArrayOf(1), "song", "mp3", "audio/mpeg", SaveLocation.MUSIC), "audio", "Music/probe/")
    }

    @Test
    fun `any file type saved to Downloads goes to the Downloads collection`() {
        assertSavedTo(saveBytes(byteArrayOf(1), "report", "pdf", "application/pdf", SaveLocation.DOWNLOADS), "downloads", "Download/probe/")
    }

    @Test
    fun `a write session for a video in DCIM opens`() {
        val callback = RecordingCallback()
        openWriteSession("clip", "mp4", "video/mp4", SaveLocation.DCIM, callback)

        assertEquals("Events: ${callback.events}", 3, callback.awaitTerminal().type)
        assertEquals("video", mediaStore.rows.values.single().collection)
    }

    @Test
    fun `an image saved to Movies is rejected by MediaProvider and reported as INVALID_INPUT`() {
        assertInvalidInput(saveBytes(byteArrayOf(1), "photo", "png", "image/png", SaveLocation.MOVIES), "Android rejected saving image/png to Movies/")
    }

    @Test
    fun `a PDF saved to Pictures is rejected with INVALID_INPUT`() {
        assertInvalidInput(saveBytes(byteArrayOf(1), "report", "pdf", "application/pdf", SaveLocation.PICTURES), "application/pdf to Pictures/")
    }

    // ── subDir ─────────────────────────────────────────────────────────────

    @Test
    fun `a subDir with a dot-dot segment is rejected`() {
        assertInvalidInput(
            saveBytes(byteArrayOf(1), "photo", "png", "image/png", SaveLocation.PICTURES, subDir = "../Android/data"),
            "..",
        )
    }

    @Test
    fun `a write session with a dot-dot subDir is rejected`() {
        val callback = RecordingCallback()
        openWriteSession("photo", "png", "image/png", SaveLocation.PICTURES, callback, subDir = "album/../..")

        assertInvalidInput(callback, "..")
    }

    @Test
    fun `a nested subDir is kept`() {
        assertSavedTo(
            saveBytes(byteArrayOf(1), "photo", "png", "image/png", SaveLocation.PICTURES, subDir = "trip/day 1"),
            "images",
            "Pictures/trip/day 1/",
        )
    }

    // ── failures leave nothing behind ──────────────────────────────────────

    @Test
    fun `a save whose IS_PENDING flag can't be cleared fails and removes the row`() {
        mediaStore.updateResult = { _, values -> if (values.containsKey("is_pending")) 0 else 1 }

        val callback = saveBytes(byteArrayOf(1, 2, 3), "photo", "png", "image/png", SaveLocation.PICTURES)

        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(Constants.ERROR_FILE_IO, event.data)
        assertTrue(mediaStore.rows.isEmpty())
    }

    @Test
    fun `a non-IO exception while writing removes the new row`() {
        // The fake numbers rows from 1, so the first insert gets this URI.
        val firstRow = Uri.parse("content://media/external_primary/images/media/1")
        shadowOf(context.contentResolver).registerOutputStream(
            firstRow,
            object : OutputStream() {
                override fun write(b: Int) = throw SecurityException("grant revoked")

                override fun write(
                    b: ByteArray,
                    off: Int,
                    len: Int,
                ) = throw SecurityException("grant revoked")
            },
        )

        val callback = saveBytes(byteArrayOf(1, 2, 3), "photo", "png", "image/png", SaveLocation.PICTURES)

        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(Constants.ERROR_PERMISSION_DENIED, event.data)
        assertTrue(mediaStore.rows.isEmpty())
        assertNoCrash()
    }

    // ── Android 9 and below ────────────────────────────────────────────────

    private fun legacyDir(location: String) = Environment.getExternalStoragePublicDirectory(location)

    @Test
    @Config(sdk = [28])
    fun `on Android 9 a dot-dot subDir is rejected and nothing is written outside the public directory`() {
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val escaped = File(legacyDir(Environment.DIRECTORY_PICTURES), "../../escaped.png").canonicalFile

        val callback = saveBytes(byteArrayOf(1), "escaped", "png", "image/png", SaveLocation.PICTURES, subDir = "../..")

        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertFalse(escaped.exists())
    }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 auto-rename of a file without extension doesn't add a trailing dot`() {
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        fun save() = saveBytes(byteArrayOf(1), "notes", "", "application/octet-stream", SaveLocation.DOWNLOADS).awaitTerminal()

        assertEquals(3, save().type)
        val second = save()

        assertEquals(3, second.type)
        assertEquals("notes (1)", File(Uri.parse(second.data).path!!).name)
    }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 any file type can still be saved to Pictures`() {
        // Plain files have no MediaStore collection rules, so this keeps working.
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)

        val event = saveBytes(byteArrayOf(1), "report", "pdf", "application/pdf", SaveLocation.PICTURES).awaitTerminal()

        assertEquals(3, event.type)
        assertEquals(File(legacyDir(Environment.DIRECTORY_PICTURES), "probe/report.pdf"), File(Uri.parse(event.data).path!!))
    }

    @Test
    fun `conflict resolution still works in the Video collection`() {
        assertEquals(3, saveBytes(byteArrayOf(1), "clip", "mp4", "video/mp4", SaveLocation.DCIM).awaitTerminal().type)

        val second = saveBytes(byteArrayOf(2), "clip", "mp4", "video/mp4", SaveLocation.DCIM, conflictResolution = ConflictResolution.SKIP)

        assertEquals(3, second.awaitTerminal().type)
        assertEquals(1, mediaStore.rows.size)
    }
}
