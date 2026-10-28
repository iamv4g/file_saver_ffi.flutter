package com.vanvixi.file_saver_ffi.utils

import com.vanvixi.file_saver_ffi.exception.NetworkDownloadException
import kotlinx.coroutines.CoroutineStart
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.awaitCancellation
import kotlinx.coroutines.coroutineScope
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext
import org.json.JSONException
import org.json.JSONObject
import java.io.FilterInputStream
import java.io.IOException
import java.io.InputStream
import java.net.HttpURLConnection
import java.net.MalformedURLException
import java.net.SocketTimeoutException
import java.net.URL

object NetworkHelper {
    /** Redirect hops followed before giving up. */
    const val MAX_REDIRECTS = 5

    private val REDIRECT_CODES = setOf(301, 302, 303, 307, 308)

    /** Headers that must not be sent to another host after a redirect. */
    private val CREDENTIAL_HEADERS = setOf("authorization", "cookie", "proxy-authorization")

    /**
     * An open HTTP response.
     *
     * @param body The response body. A failure while reading it, including the
     *   connection closing before [contentLength] bytes arrived, is thrown as
     *   [NetworkDownloadException], so callers can tell it from a storage error.
     * @param contentLength Content length from the response headers (-1 if unknown)
     */
    class Response(
        val body: InputStream,
        val contentLength: Long,
    )

    /**
     * Requests [urlString] and passes the successful response to [block].
     *
     * Follows up to [MAX_REDIRECTS] redirects, including between http and
     * https, which [HttpURLConnection] doesn't follow by itself. Credential
     * headers are dropped once a redirect leaves the original host.
     *
     * The connection is closed when [block] returns or throws, and as soon as
     * the calling coroutine is cancelled, so a cancel doesn't wait for a
     * blocked `connect()` or `read()` to time out.
     *
     * @param headersJson Optional JSON object of HTTP headers (e.g. {"Authorization":"Bearer ..."})
     * @param timeoutMs Timeout in milliseconds for connecting and for each read
     * @throws IllegalArgumentException if [headersJson] isn't a JSON object of strings
     * @throws NetworkDownloadException on an invalid URL, a connection failure,
     *   an HTTP error, too many redirects, or a failure while reading the body
     */
    suspend fun <T> download(
        urlString: String,
        headersJson: String?,
        timeoutMs: Int,
        block: suspend (Response) -> T,
    ): T =
        withContext(Dispatchers.IO) {
            val headers = parseHeaders(headersJson)
            val originalHost = parseUrl(urlString).host
            var url = parseUrl(urlString)

            repeat(MAX_REDIRECTS + 1) {
                val sameHost = url.host.equals(originalHost, ignoreCase = true)
                val requestHeaders = if (sameHost) headers else headers.filterKeys { it.lowercase() !in CREDENTIAL_HEADERS }
                val connection = open(url, requestHeaders, timeoutMs)

                val step =
                    closeOnCancel(connection) {
                        val status = connect(connection)
                        if (status in REDIRECT_CODES) {
                            val location =
                                connection.getHeaderField("Location")
                                    ?: throw NetworkDownloadException("Redirect without a Location header", status)
                            Step.Redirect(location)
                        } else {
                            if (status !in 200..299) {
                                throw NetworkDownloadException(connection.responseMessage ?: "Unknown error", status)
                            }
                            val contentLength = connection.contentLengthLong
                            Step.Done(block(Response(NetworkInputStream(connection.inputStream, contentLength), contentLength)))
                        }
                    }

                when (step) {
                    is Step.Done -> return@withContext step.value
                    is Step.Redirect ->
                        url =
                            try {
                                URL(url, step.location)
                            } catch (e: MalformedURLException) {
                                throw NetworkDownloadException("Invalid redirect location: ${step.location}")
                            }
                }
            }
            throw NetworkDownloadException("Too many redirects (more than $MAX_REDIRECTS)")
        }

    private sealed interface Step<out T> {
        class Done<T>(
            val value: T,
        ) : Step<T>

        class Redirect(
            val location: String,
        ) : Step<Nothing>
    }

    private fun parseUrl(urlString: String): URL {
        val url =
            try {
                URL(urlString)
            } catch (_: MalformedURLException) {
                throw NetworkDownloadException("Invalid URL: $urlString")
            }
        if (url.protocol != "http" && url.protocol != "https") {
            throw NetworkDownloadException("Unsupported URL scheme: $urlString")
        }
        return url
    }

    private fun open(
        url: URL,
        headers: Map<String, String>,
        timeoutMs: Int,
    ): HttpURLConnection {
        if (url.protocol != "http" && url.protocol != "https") {
            throw NetworkDownloadException("Redirect to an unsupported URL scheme: $url")
        }
        return try {
            (url.openConnection() as HttpURLConnection).apply {
                connectTimeout = timeoutMs
                readTimeout = timeoutMs
                requestMethod = "GET"
                // Followed by [download], so a change between http and https works too.
                instanceFollowRedirects = false
                headers.forEach { (key, value) -> setRequestProperty(key, value) }
            }
        } catch (e: IOException) {
            throw NetworkDownloadException("Failed to open connection: ${e.message}")
        }
    }

    /** Connects and returns the HTTP status code. */
    private fun connect(connection: HttpURLConnection): Int =
        try {
            connection.connect()
            connection.responseCode
        } catch (e: SocketTimeoutException) {
            throw NetworkDownloadException("Timed out connecting to ${connection.url.host}")
        } catch (e: IOException) {
            throw NetworkDownloadException("Connection failed: ${e.message}")
        }

    /**
     * Runs [block] and closes [connection] when it ends, or as soon as the
     * caller is cancelled. Closing the connection makes a blocked `connect()`
     * or `read()` fail at once; that failure is reported as the cancellation.
     */
    private suspend fun <T> closeOnCancel(
        connection: HttpURLConnection,
        block: suspend () -> T,
    ): T =
        coroutineScope {
            val watcher =
                launch(start = CoroutineStart.UNDISPATCHED) {
                    try {
                        awaitCancellation()
                    } finally {
                        connection.disconnect()
                    }
                }
            try {
                block()
            } catch (e: IOException) {
                ensureActive()
                throw e
            } finally {
                watcher.cancel()
            }
        }

    /**
     * Parses a JSON object into HTTP headers.
     *
     * @return The headers, or an empty map if [headersJson] is null or blank
     * @throws IllegalArgumentException if [headersJson] isn't a JSON object of strings
     */
    private fun parseHeaders(headersJson: String?): Map<String, String> {
        if (headersJson.isNullOrBlank()) return emptyMap()

        return try {
            val json = JSONObject(headersJson)
            json.keys().asSequence().associateWith { key ->
                json.get(key) as? String ?: throw IllegalArgumentException("Header '$key' must be a string")
            }
        } catch (e: JSONException) {
            throw IllegalArgumentException("headers must be a JSON object of strings: ${e.message}", e)
        }
    }

    /**
     * Reports failures while reading a response body as network errors, and a
     * body that ends before [expectedLength] bytes as a failure instead of a
     * short file.
     */
    private class NetworkInputStream(
        input: InputStream,
        private val expectedLength: Long,
    ) : FilterInputStream(input) {
        private var bytesRead = 0L

        override fun read(): Int =
            guard {
                val byte = super.read()
                if (byte >= 0) bytesRead++ else checkComplete()
                byte
            }

        override fun read(
            b: ByteArray,
            off: Int,
            len: Int,
        ): Int =
            guard {
                val count = super.read(b, off, len)
                if (count > 0) bytesRead += count else if (count < 0) checkComplete()
                count
            }

        private fun checkComplete() {
            if (expectedLength >= 0 && bytesRead < expectedLength) {
                throw NetworkDownloadException("Connection closed after $bytesRead of $expectedLength bytes")
            }
        }

        private inline fun <T> guard(read: () -> T): T =
            try {
                read()
            } catch (e: NetworkDownloadException) {
                throw e
            } catch (e: SocketTimeoutException) {
                throw NetworkDownloadException("Timed out after $bytesRead bytes waiting for more data")
            } catch (e: IOException) {
                throw NetworkDownloadException("Connection failed after $bytesRead bytes: ${e.message}")
            }
    }
}
