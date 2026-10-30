package com.iamv4g.file_saver_ffi

import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.testing.TestHttpServer
import com.iamv4g.file_saver_ffi.testing.useOkHttpUrlConnection
import com.iamv4g.file_saver_ffi.utils.Constants
import org.junit.After
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertFalse
import org.junit.Assert.assertNull
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config
import java.net.ServerSocket
import java.util.concurrent.CountDownLatch
import java.util.concurrent.TimeUnit

/**
 * [FileSaver.saveNetwork] against a local [TestHttpServer].
 *
 * `HttpURLConnection` is backed by OkHttp here, as it is on Android. The JDK's
 * own implementation differs: its `disconnect()` waits for a blocked read.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class NetworkSaveTest : FileSaverTestBase() {
    private lateinit var server: TestHttpServer
    private val payload = ByteArray(3 * Constants.CHUNK_SIZE + 123) { (it % 251).toByte() }

    @Before
    fun startServer() {
        useOkHttpUrlConnection()
        server = TestHttpServer()
    }

    @After
    fun stopServer() {
        server.close()
    }

    private fun download(
        url: String,
        headersJson: String? = null,
        timeoutMs: Int = 5_000,
        callback: RecordingCallback = RecordingCallback(),
    ): Pair<Long, RecordingCallback> {
        val id =
            fileSaver.saveNetwork(
                url,
                headersJson,
                timeoutMs,
                "download",
                "bin",
                "application/octet-stream",
                SaveLocation.DOWNLOADS.ordinal,
                null,
                ConflictResolution.AUTO_RENAME.value,
                callback,
            )
        return id to callback
    }

    private fun assertNetworkError(
        callback: RecordingCallback,
        messageContains: String,
    ) {
        val event = callback.awaitTerminal(timeoutMs = 10_000)
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertEquals(event.message, Constants.ERROR_NETWORK, event.data)
        assertTrue(event.message, event.message!!.contains(messageContains))
        assertTrue("Rows left: ${mediaStore.rows}", mediaStore.rows.isEmpty())
    }

    private fun awaitNoRows(timeoutMs: Long) {
        val deadline = System.currentTimeMillis() + timeoutMs
        while (mediaStore.rows.isNotEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
    }

    // ── success ────────────────────────────────────────────────────────────

    @Test
    fun `downloads the body and completes`() {
        server.serve("/file", payload)

        val (_, callback) = download(server.url("/file"))

        assertEquals("Events: ${callback.events}", 3, callback.awaitTerminal().type)
        assertArrayEquals(payload, mediaStore.rowNamed("download.bin")!!.file.readBytes())
        assertTrue(callback.events.count { it.type == 1 } >= 4)
    }

    @Test
    fun `downloads a body without Content-Length`() {
        server.serveUnknownLength("/stream", payload)

        val (_, callback) = download(server.url("/stream"))

        assertEquals("Events: ${callback.events}", 3, callback.awaitTerminal().type)
        assertArrayEquals(payload, mediaStore.rowNamed("download.bin")!!.file.readBytes())
    }

    @Test
    fun `sends the request headers`() {
        server.serve("/file", payload)

        val (_, callback) = download(server.url("/file"), headersJson = """{"Authorization":"Bearer t0ken","X-Trace":"42"}""")

        assertEquals(3, callback.awaitTerminal().type)
        val headers = server.requests.single().headers
        assertEquals("Bearer t0ken", headers["authorization"])
        assertEquals("42", headers["x-trace"])
    }

    // ── errors are network errors ──────────────────────────────────────────

    @Test
    fun `an HTTP error reports NETWORK_ERROR with the status`() {
        val (_, callback) = download(server.url("/missing"))

        assertNetworkError(callback, "(HTTP 404)")
    }

    @Test
    fun `a body that ends early is a network error, not a short file`() {
        server.truncate("/short", declaredLength = payload.size, sent = Constants.CHUNK_SIZE)

        val (_, callback) = download(server.url("/short"))

        assertNetworkError(callback, "Network download failed")
    }

    @Test
    fun `a stalled body times out as a network error`() {
        server.stall("/stall", declaredLength = payload.size, sent = 1_000)

        val (_, callback) = download(server.url("/stall"), timeoutMs = 1_000)

        assertNetworkError(callback, "Timed out")
    }

    @Test
    fun `a server that never answers times out as a network error`() {
        server.hang("/hang")

        val (_, callback) = download(server.url("/hang"), timeoutMs = 1_000)

        assertNetworkError(callback, "Timed out")
    }

    @Test
    fun `a refused connection is a network error`() {
        val closedPort = ServerSocket(0).use { it.localPort }

        val (_, callback) = download("http://127.0.0.1:$closedPort/file")

        assertNetworkError(callback, "Connection failed")
    }

    // ── cancel doesn't wait for the timeout ────────────────────────────────

    @Test
    fun `cancelling a stalled body closes the connection and removes the row right away`() {
        val clientClosed = CountDownLatch(1)
        server.stall("/stall", declaredLength = payload.size, sent = 1_000, onClientClosed = clientClosed)

        val (id, callback) = download(server.url("/stall"), timeoutMs = 60_000)
        val deadline = System.currentTimeMillis() + 5_000
        while (mediaStore.rows.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)
        assertEquals("Row should exist while downloading", 1, mediaStore.rows.size)

        fileSaver.cancelOperation(id)

        assertTrue("Connection still open 3 s after cancel", clientClosed.await(3, TimeUnit.SECONDS))
        awaitNoRows(3_000)
        assertTrue("Rows left: ${mediaStore.rows}", mediaStore.rows.isEmpty())
        assertTrue(callback.events.none { it.type == 2 || it.type == 3 })
    }

    @Test
    fun `cancelling while waiting for the response headers closes the connection right away`() {
        val clientClosed = CountDownLatch(1)
        server.hang("/hang", onClientClosed = clientClosed)

        val (id, callback) = download(server.url("/hang"), timeoutMs = 60_000)
        val deadline = System.currentTimeMillis() + 5_000
        while (server.requests.isEmpty() && System.currentTimeMillis() < deadline) Thread.sleep(20)

        fileSaver.cancelOperation(id)

        assertTrue("Connection still open 3 s after cancel", clientClosed.await(3, TimeUnit.SECONDS))
        assertTrue(callback.events.none { it.type == 2 || it.type == 3 })
    }

    // ── redirects ──────────────────────────────────────────────────────────

    @Test
    fun `follows a relative redirect`() {
        server.serve("/file", payload)
        server.redirect("/old", "/file", status = 301)

        val (_, callback) = download(server.url("/old"))

        assertEquals("Events: ${callback.events}", 3, callback.awaitTerminal().type)
        assertEquals(listOf("/old", "/file"), server.requests.map { it.path })
    }

    @Test
    fun `follows a redirect to an https URL instead of failing with the 3xx status`() {
        // Nothing listens there, so the save fails, but only after following.
        val closedPort = ServerSocket(0).use { it.localPort }
        server.redirect("/to-https", "https://127.0.0.1:$closedPort/file")

        val (_, callback) = download(server.url("/to-https"))

        val event = callback.awaitTerminal(timeoutMs = 10_000)
        assertEquals("Events: ${callback.events}", 2, event.type)
        assertFalse(event.message, event.message!!.contains("HTTP 302"))
        assertTrue(event.message, event.message!!.contains("Connection failed"))
    }

    @Test
    fun `keeps credentials on a same-host redirect and drops them for another host`() {
        server.serve("/file", payload)
        server.redirect("/same", "/file")
        server.redirect("/other", server.url("/file", host = "localhost"))
        val auth = """{"Authorization":"Bearer t0ken","Cookie":"s=1","X-Trace":"42"}"""

        assertEquals(3, download(server.url("/same"), headersJson = auth).second.awaitTerminal().type)
        assertEquals("Bearer t0ken", server.requests.last().headers["authorization"])

        mediaStore.rows.clear()
        assertEquals(3, download(server.url("/other"), headersJson = auth).second.awaitTerminal().type)
        val redirected = server.requests.last()
        assertEquals("localhost", redirected.host)
        assertNull(redirected.headers["authorization"])
        assertNull(redirected.headers["cookie"])
        assertEquals("42", redirected.headers["x-trace"])
    }

    @Test
    fun `gives up after too many redirects`() {
        server.redirect("/loop", "/loop")

        val (_, callback) = download(server.url("/loop"))

        assertNetworkError(callback, "Too many redirects")
        assertEquals(6, server.requests.size)
    }

    // ── headers ────────────────────────────────────────────────────────────

    @Test
    fun `malformed headers JSON is INVALID_INPUT and sends no request`() {
        server.serve("/file", payload)

        val (_, callback) = download(server.url("/file"), headersJson = "{not json")

        val event = callback.awaitTerminal()
        assertEquals(2, event.type)
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertTrue(server.requests.isEmpty())
    }

    @Test
    fun `a non-string header value is INVALID_INPUT`() {
        server.serve("/file", payload)

        val (_, callback) = download(server.url("/file"), headersJson = """{"X-Count":3}""")

        val event = callback.awaitTerminal()
        assertEquals(Constants.ERROR_INVALID_INPUT, event.data)
        assertTrue(event.message!!.contains("X-Count"))
        assertTrue(server.requests.isEmpty())
    }
}
