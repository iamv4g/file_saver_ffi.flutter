package com.iamv4g.file_saver_ffi

import android.content.Intent
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.testing.FakeDocumentsProvider
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.Constants
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * Saves to a user-picked directory (Storage Access Framework), against
 * [FakeDocumentsProvider].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class SafSaveTest : FileSaverTestBase() {
    private lateinit var documents: FakeDocumentsProvider

    @Before
    fun installDocumentsProvider() {
        documents = FakeDocumentsProvider.install()
        // A picked directory comes with a persisted read/write grant.
        context.grantUriPermission(
            context.packageName,
            documents.treeUri,
            Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
        )
    }

    @Test
    fun `saves a new document with the requested name`() {
        val event = saveAs("note", ConflictResolution.AUTO_RENAME, byteArrayOf(1, 2))

        assertEquals("Events: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(1, 2), documents.contentOf("note.txt"))
    }

    @Test
    fun `autoRename picks the first free name from a single directory listing`() {
        documents.addExisting("note.txt")
        (1..5).forEach { documents.addExisting("note ($it).txt") }
        documents.childQueries.set(0)

        val event = saveAs("note", ConflictResolution.AUTO_RENAME, byteArrayOf(7))

        assertEquals("Events: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(7), documents.contentOf("note (6).txt"))
        assertEquals("directory listings", 1, documents.childQueries.get())
    }

    @Test
    fun `autoRename uses (999) when it is the first free name`() {
        documents.addExisting("note.txt")
        (1..998).forEach { documents.addExisting("note ($it).txt") }

        val event = saveAs("note", ConflictResolution.AUTO_RENAME, byteArrayOf(9))

        assertEquals("Events: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(9), documents.contentOf("note (999).txt"))
    }

    @Test
    fun `autoRename keeps counting past 999`() {
        documents.addExisting("note.txt")
        (1..999).forEach { documents.addExisting("note ($it).txt") }

        val event = saveAs("note", ConflictResolution.AUTO_RENAME, byteArrayOf(9))

        assertEquals("Events: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(9), documents.contentOf("note (1000).txt"))
    }

    @Test
    fun `autoRename of a name without an extension adds no trailing dot`() {
        documents.addExisting("README", "application/octet-stream")

        val event = saveAs("README", ConflictResolution.AUTO_RENAME, byteArrayOf(1), ext = "", mimeType = "application/octet-stream")

        assertEquals("Events: $event", 3, event.type)
        assertTrue(documents.names().toString(), "README (1)" in documents.names())
    }

    @Test
    fun `skip completes with the existing document and writes nothing`() {
        val existing = documents.addExisting("note.txt")

        val event = saveAs("note", ConflictResolution.SKIP, byteArrayOf(1))

        assertEquals(3, event.type)
        assertTrue(event.data!!.endsWith(existing.id))
        assertEquals(listOf("note.txt"), documents.names())
    }

    @Test
    fun `fail reports FILE_EXISTS`() {
        documents.addExisting("note.txt")

        val event = saveAs("note", ConflictResolution.FAIL, byteArrayOf(1))

        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_FILE_EXISTS, event.data)
        assertEquals(listOf("note.txt"), documents.names())
    }

    @Test
    fun `overwrite replaces the existing document under the same name`() {
        documents.addExisting("note.txt")

        val event = saveAs("note", ConflictResolution.OVERWRITE, byteArrayOf(5, 6))

        assertEquals("Events: $event", 3, event.type)
        assertEquals(listOf("note.txt"), documents.names())
        assertArrayEquals(byteArrayOf(5, 6), documents.contentOf("note.txt"))
    }

    @Test
    fun `overwrite replaces the document however many numbered copies exist`() {
        // The system provider numbers a taken name only up to `name (32)`.
        documents.addExisting("note.txt")
        (1..32).forEach { documents.addExisting("note ($it).txt") }

        val event = saveAs("note", ConflictResolution.OVERWRITE, byteArrayOf(5, 6))

        assertEquals("Events: $event", 3, event.type)
        assertEquals(documents.names().toString(), 33, documents.names().size)
        assertEquals(1, documents.names().count { it == "note.txt" })
        assertArrayEquals(byteArrayOf(5, 6), documents.contentOf("note.txt"))
    }

    @Test
    fun `cancelling right after the document is created deletes it`() {
        val opening = CountDownLatch(1)
        val release = CountDownLatch(1)
        // Runs while the entry is being created: the document exists, but the
        // save hasn't got the entry yet.
        documents.beforeOpenDocument = {
            opening.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val callback = RecordingCallback()

        val operationId =
            fileSaver.saveBytesAs(byteArrayOf(1), documents.treeUri.toString(), "note", "txt", "text/plain", ConflictResolution.AUTO_RENAME.value, callback)
        assertTrue(opening.await(5, TimeUnit.SECONDS))
        assertEquals(listOf("note.txt"), documents.names())
        fileSaver.cancelOperation(operationId)
        release.countDown()

        assertEquals("Events: ${callback.events}", 4, callback.awaitTerminal().type)
        assertEquals(emptyList<String>(), documents.names())
        assertNoCrash()
    }

    private fun saveAs(
        name: String,
        conflictResolution: ConflictResolution,
        data: ByteArray,
        ext: String = "txt",
        mimeType: String = "text/plain",
    ) = RecordingCallback()
        .also {
            fileSaver.saveBytesAs(data, documents.treeUri.toString(), name, ext, mimeType, conflictResolution.value, it)
        }.awaitTerminal()
}
