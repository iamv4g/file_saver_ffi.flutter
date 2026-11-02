package com.iamv4g.file_saver_ffi

import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FakeMediaStoreProvider
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.Constants
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.io.File
import java.nio.file.Files
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit
import java.util.concurrent.atomic.AtomicBoolean

/**
 * [FileSaver.copyToPath], which reads a `content://` source for a Dart
 * `PathLocation` save, against [FakeMediaStoreProvider].
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class CopyToPathTest : FileSaverTestBase() {
    private lateinit var dir: File

    /** The file the Dart side claimed, which the copy goes into. */
    private lateinit var target: File

    @Before
    fun createTarget() {
        dir = Files.createTempDirectory("copy-to-path").toFile()
        target = File(dir, "copy.bin").apply { createNewFile() }
    }

    @After
    fun deleteDir() {
        dir.deleteRecursively()
    }

    /** Saves [data] to the fake MediaStore and returns the content URI of the row. */
    private fun contentUri(data: ByteArray): String {
        val event = saveBytes(data, "source", "bin", "application/octet-stream", SaveLocation.DOWNLOADS).awaitTerminal()
        assertEquals("Events: $event", 3, event.type)
        return event.data!!
    }

    @Test
    fun `copies a content URI into the target, with progress, and reports the target`() {
        val data = ByteArray(3 * Constants.CHUNK_SIZE) { it.toByte() }
        val source = contentUri(data)
        val callback = RecordingCallback()

        fileSaver.copyToPath(source, target.path, callback)

        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 3, event.type)
        assertEquals(target.path, event.data)
        assertArrayEquals(data, target.readBytes())
        val progress = callback.events.filter { it.type == 1 }.map { it.progress }
        assertTrue("Progress: $progress", progress.size >= 3)
        assertEquals(progress.sorted(), progress)
        assertEquals(1.0, progress.last(), 0.0)
        assertNoCrash()
    }

    @Test
    fun `replaces what the target held`() {
        target.writeBytes(ByteArray(100) { 9 })
        val source = contentUri(byteArrayOf(1, 2, 3))
        val callback = RecordingCallback()

        fileSaver.copyToPath(source, target.path, callback)

        assertEquals(3, callback.awaitTerminal().type)
        assertArrayEquals(byteArrayOf(1, 2, 3), target.readBytes())
    }

    @Test
    fun `a content URI without a row reports FILE_NOT_FOUND with the URI`() {
        val source = "content://media/external_primary/downloads/404"
        val callback = RecordingCallback()

        fileSaver.copyToPath(source, target.path, callback)

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_FILE_NOT_FOUND, event.data)
        assertEquals(source, event.message)
        assertNoCrash()
    }

    @Test
    fun `an unsupported scheme reports INVALID_INPUT`() {
        val callback = RecordingCallback()

        fileSaver.copyToPath("https://example.com/a.bin", target.path, callback)

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertNoCrash()
    }

    @Test
    fun `a target that can't be written reports FILE_IO_ERROR without reading the source`() {
        val source = contentUri(byteArrayOf(1))
        val opened = AtomicBoolean(false)
        mediaStore.beforeOpenFile = { opened.set(true) }
        val callback = RecordingCallback()

        fileSaver.copyToPath(source, File(dir, "missing/copy.bin").path, callback)

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_FILE_IO, event.data)
        assertFalse("The source was opened", opened.get())
        assertNoCrash()
    }

    @Test
    fun `cancelling reports cancelled once the copy has stopped, and writes nothing`() {
        val source = contentUri(ByteArray(3 * Constants.CHUNK_SIZE) { 1 })
        val opening = CountDownLatch(1)
        val release = CountDownLatch(1)
        mediaStore.beforeOpenFile = {
            opening.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val callback = RecordingCallback()

        val operationId = fileSaver.copyToPath(source, target.path, callback)
        assertTrue(opening.await(5, TimeUnit.SECONDS))
        fileSaver.cancelOperation(operationId)
        Thread.sleep(100)
        // Still opening the source.
        assertTrue("Events: ${callback.events}", callback.events.isEmpty())

        release.countDown()
        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 4, event.type)
        assertEquals(listOf(4), callback.events.map { it.type })
        assertEquals(0L, target.length())
        assertNoCrash()
    }

    @Test
    fun `cancelling right away reports cancelled`() {
        val source = contentUri(byteArrayOf(1))
        val callback = RecordingCallback()

        fileSaver.cancelOperation(fileSaver.copyToPath(source, target.path, callback))

        val event = callback.awaitTerminal()
        assertTrue("Events: ${callback.events}", event.type == 4 || event.type == 3)
        assertNoCrash()
    }
}
