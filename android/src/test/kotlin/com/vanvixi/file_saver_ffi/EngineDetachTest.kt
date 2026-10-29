package com.vanvixi.file_saver_ffi

import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.SaveLocation
import com.vanvixi.file_saver_ffi.testing.FakeEngine
import com.vanvixi.file_saver_ffi.testing.FileSaverTestBase
import com.vanvixi.file_saver_ffi.testing.RecordingCallback
import com.vanvixi.file_saver_ffi.testing.TestHttpServer
import com.vanvixi.file_saver_ffi.testing.useOkHttpUrlConnection
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
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * When an engine is destroyed, the saves and write sessions of the
 * [FileSaver]s its Dart side created are cancelled, and only those.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class EngineDetachTest : FileSaverTestBase() {
    private lateinit var server: TestHttpServer
    private val engines = mutableListOf<FakeEngine>()

    @Before
    fun startServer() {
        useOkHttpUrlConnection()
        server = TestHttpServer()
    }

    @After
    fun tearDown() {
        engines.forEach { it.destroy() }
        server.close()
    }

    @Test
    fun `destroying an engine stops its download and deletes the partial file`() {
        val engine = engine()
        val clientClosed = CountDownLatch(1)
        server.stall("/stall", declaredLength = 100_000, sent = 1_000, onClientClosed = clientClosed)
        val callback = RecordingCallback()
        download(FileSaver(engine.id), callback)
        awaitRows(1)

        engine.destroy()

        assertTrue("Connection still open 3 s after the engine was destroyed", clientClosed.await(3, TimeUnit.SECONDS))
        awaitRows(0)
        assertTrue("Events: ${callback.events}", callback.events.none { it.type == 2 || it.type == 3 })
        assertNoCrash()
    }

    @Test
    fun `destroying an engine discards its open write sessions`() {
        val engine = engine()
        val saver = FileSaver(engine.id)
        val sessionId = openSession(saver, "log")
        writeChunk(saver, sessionId, byteArrayOf(1, 2, 3))
        assertEquals(1, mediaStore.rows.size)

        engine.destroy()

        awaitRows(0)
        assertNoCrash()
    }

    @Test
    fun `destroying an engine leaves the saves of other engines running`() {
        val destroyed = engine()
        val running = engine()
        val runningSaver = FileSaver(running.id)
        val sessionId = openSession(runningSaver, "kept")
        openSession(FileSaver(destroyed.id), "discarded")

        destroyed.destroy()
        awaitRows(1)

        writeChunk(runningSaver, sessionId, byteArrayOf(4, 5))
        val close = RecordingCallback()
        runningSaver.closeSession(sessionId, close)
        assertEquals(3, close.awaitTerminal().type)
        val row = mediaStore.rowNamed("kept.txt")!!
        assertFalse(row.isPending)
        assertArrayEquals(byteArrayOf(4, 5), row.file.readBytes())
    }

    @Test
    fun `a FileSaver without an engine is not cancelled when an engine is destroyed`() {
        val engine = engine()
        val sessionId = openSession(fileSaver, "kept")

        engine.destroy()

        writeChunk(fileSaver, sessionId, byteArrayOf(6))
        val close = RecordingCallback()
        fileSaver.closeSession(sessionId, close)
        assertEquals(3, close.awaitTerminal().type)
        assertFalse(mediaStore.rowNamed("kept.txt")!!.isPending)
    }

    // ── helpers ────────────────────────────────────────────────────────────

    private fun engine() = FakeEngine(context).also { engines += it }

    private fun download(
        saver: FileSaver,
        callback: RecordingCallback,
    ) = saver.saveNetwork(
        server.url("/stall"),
        null,
        60_000,
        "download",
        "bin",
        "application/octet-stream",
        SaveLocation.DOWNLOADS.ordinal,
        null,
        ConflictResolution.AUTO_RENAME.value,
        callback,
    )

    /** Opens a session for `<name>.txt` in Downloads and returns its id. */
    private fun openSession(
        saver: FileSaver,
        name: String,
    ): Long {
        val open = RecordingCallback()
        saver.openWriteSession(name, "txt", "text/plain", SaveLocation.DOWNLOADS.ordinal, null, ConflictResolution.AUTO_RENAME.value, -1, open)
        val opened = open.awaitTerminal()
        assertEquals("Events: ${open.events}", 3, opened.type)
        return opened.data!!.toLong()
    }

    private fun writeChunk(
        saver: FileSaver,
        sessionId: Long,
        data: ByteArray,
    ) {
        val written = RecordingCallback()
        saver.writeChunk(sessionId, data, written)
        assertEquals("Events: ${written.events}", 1, written.awaitEvents(1).type)
    }

    private fun awaitRows(count: Int) {
        val deadline = System.currentTimeMillis() + 3_000
        while (mediaStore.rows.size != count && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals("Rows: ${mediaStore.rows.values.map { it.displayName }}", count, mediaStore.rows.size)
    }
}
