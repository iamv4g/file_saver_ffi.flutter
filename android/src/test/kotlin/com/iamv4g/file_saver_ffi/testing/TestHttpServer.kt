package com.iamv4g.file_saver_ffi.testing

import java.io.BufferedReader
import java.io.InputStreamReader
import java.io.OutputStream
import java.net.InetAddress
import java.net.ServerSocket
import java.net.Socket
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.CopyOnWriteArrayList
import java.util.concurrent.CountDownLatch
import kotlin.concurrent.thread

/**
 * Minimal HTTP/1.1 server on a loopback port, with full control over what
 * goes on the wire: responses that stall, end early or never send headers.
 *
 * Reach it as `http://127.0.0.1:<port>` or, for a different host name,
 * `http://localhost:<port>`.
 */
class TestHttpServer : AutoCloseable {
    /** A request as received. Header names are lower-cased. */
    data class Request(
        val path: String,
        val host: String,
        val headers: Map<String, String>,
    )

    /** Writes a response to [out]. Return to close the connection. */
    fun interface Handler {
        fun handle(
            request: Request,
            out: OutputStream,
            socket: Socket,
        )
    }

    private val server = ServerSocket(0, 50, InetAddress.getLoopbackAddress())
    private val routes = ConcurrentHashMap<String, Handler>()
    private val sockets = CopyOnWriteArrayList<Socket>()
    private val closed = CountDownLatch(1)

    val requests = CopyOnWriteArrayList<Request>()
    val port get() = server.localPort

    init {
        thread(isDaemon = true, name = "TestHttpServer") {
            while (!server.isClosed) {
                val socket =
                    try {
                        server.accept()
                    } catch (_: Exception) {
                        break
                    }
                sockets += socket
                thread(isDaemon = true) { serve(socket) }
            }
        }
    }

    fun url(
        path: String,
        host: String = "127.0.0.1",
    ) = "http://$host:$port$path"

    fun route(
        path: String,
        handler: Handler,
    ) {
        routes[path] = handler
    }

    /** Responds with [body] and its Content-Length. */
    fun serve(
        path: String,
        body: ByteArray,
        status: Int = 200,
    ) = route(path) { _, out, _ ->
        out.write("HTTP/1.1 $status ${reason(status)}\r\nContent-Length: ${body.size}\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(body)
    }

    fun redirect(
        path: String,
        location: String,
        status: Int = 302,
    ) = route(path) { _, out, _ ->
        out.write("HTTP/1.1 $status ${reason(status)}\r\nLocation: $location\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
    }

    /** Sends headers for [declaredLength] bytes, then [sent] bytes, then waits until the client disconnects or the server closes. */
    fun stall(
        path: String,
        declaredLength: Int,
        sent: Int,
        onClientClosed: CountDownLatch? = null,
    ) = route(path) { _, out, socket ->
        out.write("HTTP/1.1 200 OK\r\nContent-Length: $declaredLength\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(ByteArray(sent))
        out.flush()
        awaitClientClose(socket, onClientClosed)
    }

    /** Reads the request and never answers, until the client disconnects or the server closes. */
    fun hang(
        path: String,
        onClientClosed: CountDownLatch? = null,
    ) = route(path) { _, _, socket -> awaitClientClose(socket, onClientClosed) }

    /** Sends headers for [declaredLength] bytes, then only [sent] bytes, and closes the connection. */
    fun truncate(
        path: String,
        declaredLength: Int,
        sent: Int,
    ) = route(path) { _, out, _ ->
        out.write("HTTP/1.1 200 OK\r\nContent-Length: $declaredLength\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(ByteArray(sent))
    }

    /** Responds with [body] without a Content-Length, ending it by closing the connection. */
    fun serveUnknownLength(
        path: String,
        body: ByteArray,
    ) = route(path) { _, out, _ ->
        out.write("HTTP/1.1 200 OK\r\nConnection: close\r\n\r\n".toByteArray())
        out.write(body)
    }

    override fun close() {
        closed.countDown()
        server.close()
        sockets.forEach { runCatching { it.close() } }
    }

    private fun serve(socket: Socket) {
        socket.use {
            val reader = BufferedReader(InputStreamReader(socket.getInputStream(), Charsets.ISO_8859_1))
            val requestLine = reader.readLine() ?: return
            val headers = mutableMapOf<String, String>()
            while (true) {
                val line = reader.readLine() ?: return
                if (line.isEmpty()) break
                headers[line.substringBefore(':').trim().lowercase()] = line.substringAfter(':').trim()
            }
            val path = requestLine.split(' ')[1]
            val request = Request(path, headers["host"].orEmpty().substringBefore(':'), headers)
            requests += request

            val out = socket.getOutputStream()
            val handler = routes[path.substringBefore('?')]
            if (handler == null) {
                out.write("HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".toByteArray())
            } else {
                runCatching { handler.handle(request, out, socket) }
            }
            runCatching { out.flush() }
        }
    }

    private fun awaitClientClose(
        socket: Socket,
        onClientClosed: CountDownLatch?,
    ) {
        // A read returns -1 (or throws) once the client closes its end.
        thread(isDaemon = true) {
            runCatching { while (socket.getInputStream().read() >= 0) Unit }
            onClientClosed?.countDown()
        }
        closed.await()
    }

    private fun reason(status: Int) =
        when (status) {
            200 -> "OK"
            301 -> "Moved Permanently"
            302 -> "Found"
            307 -> "Temporary Redirect"
            404 -> "Not Found"
            500 -> "Internal Server Error"
            else -> "Status"
        }
}
