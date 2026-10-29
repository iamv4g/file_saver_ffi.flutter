package com.vanvixi.file_saver_ffi

import android.content.Intent
import android.net.Uri
import com.vanvixi.file_saver_ffi.models.SaveLocation
import com.vanvixi.file_saver_ffi.testing.Event
import com.vanvixi.file_saver_ffi.testing.FileSaverTestBase
import com.vanvixi.file_saver_ffi.testing.RecordingCallback
import com.vanvixi.file_saver_ffi.utils.Constants
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * [FileSaver.canOpenFile] and [FileSaver.openFile]: they report through the
 * callback from a background thread, and failures carry an error code.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class FileOpenerTest : FileSaverTestBase() {
    // ── canOpenFile ────────────────────────────────────────────────────────

    @Test
    fun `canOpenFile returns at once and reports from the background while the provider is slow`() {
        val uri = savedUri()
        val providerCalled = CountDownLatch(1)
        val release = CountDownLatch(1)
        mediaStore.beforeOpenFile = {
            providerCalled.countDown()
            release.await(5, TimeUnit.SECONDS)
        }
        val callback = RecordingCallback()

        val started = System.nanoTime()
        fileSaver.canOpenFile(uri, callback)
        val elapsedMs = TimeUnit.NANOSECONDS.toMillis(System.nanoTime() - started)

        assertTrue("canOpenFile blocked the calling thread for $elapsedMs ms", elapsedMs < 500)
        assertTrue(providerCalled.await(5, TimeUnit.SECONDS))
        assertTrue(callback.events.isEmpty())
        release.countDown()
        assertEquals(Event(3, 1.0, "true", null), callback.awaitTerminal())
    }

    @Test
    fun `canOpenFile is false for a deleted row, a missing file and another scheme`() {
        val uri = savedUri()
        context.contentResolver.delete(Uri.parse(uri), null, null)

        assertEquals("false", canOpen(uri))
        assertEquals("false", canOpen("file:///no/such/file.txt"))
        assertEquals("false", canOpen("https://example.com/a.txt"))
    }

    @Test
    fun `canOpenFile is true for a readable file URI`() {
        val file = File.createTempFile("open", ".txt").apply { writeText("x") }

        assertEquals("true", canOpen(Uri.fromFile(file).toString()))
    }

    // ── openFile ───────────────────────────────────────────────────────────

    @Test
    fun `openFile starts a viewer for a MediaStore row`() {
        val uri = savedUri()

        assertEquals(3, open(uri).type)

        val intent = shadowOf(context).nextStartedActivity
        assertEquals(Intent.ACTION_VIEW, intent.action)
        assertEquals(Uri.parse(uri), intent.data)
        assertEquals("text/plain", intent.type)
        assertTrue(intent.flags and Intent.FLAG_GRANT_READ_URI_PERMISSION != 0)
    }

    @Test
    fun `openFile of a deleted row reports FILE_NOT_FOUND with the URI`() {
        val uri = savedUri()
        context.contentResolver.delete(Uri.parse(uri), null, null)

        assertEquals(Event(2, 0.0, Constants.ERROR_FILE_NOT_FOUND, uri), open(uri))
    }

    @Test
    fun `openFile of a missing file reports FILE_NOT_FOUND`() {
        val event = open("file:///no/such/file.txt")

        assertEquals(Constants.ERROR_FILE_NOT_FOUND, event.data)
        assertEquals("file:///no/such/file.txt", event.message)
    }

    @Test
    fun `openFile of an unsupported scheme reports INVALID_INPUT`() {
        val event = open("https://example.com/a.txt")

        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertTrue(event.message!!.contains("https"))
    }

    @Test
    fun `openFile without an app for the type reports OPEN_FAILED`() {
        shadowOf(context).checkActivities(true)

        val event = open(savedUri())

        assertEquals(Constants.ERROR_OPEN_FAILED, event.data)
        assertTrue(event.message!!.contains("No app found"))
    }

    @Test
    // Robolectric doesn't implement the API 33 overload of resolveContentProvider.
    @Config(sdk = [32])
    fun `openFile of a file URI without a FileProvider reports OPEN_FAILED`() {
        val file = File.createTempFile("open", ".txt").apply { writeText("x") }

        val event = open(Uri.fromFile(file).toString())

        assertEquals(event.message, Constants.ERROR_OPEN_FAILED, event.data)
        assertTrue(event.message!!.contains("FileProvider"))
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private fun savedUri(): String {
        val saved = saveBytes("hello".toByteArray(), "note", "txt", "text/plain", SaveLocation.DOWNLOADS)
        assertEquals("Events: ${saved.events}", 3, saved.awaitTerminal().type)
        return saved.awaitTerminal().data!!
    }

    private fun canOpen(uri: String): String? {
        val callback = RecordingCallback()
        fileSaver.canOpenFile(uri, callback)
        val event = callback.awaitTerminal()
        assertEquals("Events: ${callback.events}", 3, event.type)
        return event.data
    }

    private fun open(uri: String): Event {
        val callback = RecordingCallback()
        fileSaver.openFile(uri, null, callback)
        return callback.awaitTerminal()
    }
}
