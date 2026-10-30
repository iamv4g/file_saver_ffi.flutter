package com.iamv4g.file_saver_ffi.testing

import okhttp3.OkHttpClient
import okhttp3.OkUrlFactory
import java.net.URL

private val installed by lazy {
    try {
        URL.setURLStreamHandlerFactory(OkUrlFactory(OkHttpClient()))
    } catch (_: Error) {
        // Already installed by a test class in another Robolectric sandbox.
    }
}

/**
 * Backs `HttpURLConnection` with OkHttp, as it is on Android. The JDK's own
 * implementation differs: its `disconnect()` waits for a blocked read. The
 * JDK allows one factory per JVM, so it is installed once.
 */
fun useOkHttpUrlConnection() = installed
