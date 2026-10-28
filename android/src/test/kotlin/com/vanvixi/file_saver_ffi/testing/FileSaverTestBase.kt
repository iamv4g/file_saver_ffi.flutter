package com.vanvixi.file_saver_ffi.testing

import android.app.Application
import androidx.test.core.app.ApplicationProvider
import com.vanvixi.file_saver_ffi.FileSaver
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.SaveLocation
import org.junit.After
import org.junit.Assert.assertTrue
import org.junit.Before
import java.util.Collections

/**
 * Sets up a [FileSaver] the way the plugin does, against
 * [FakeMediaStoreProvider], and records exceptions that would crash the app.
 *
 * Subclasses run with `@RunWith(RobolectricTestRunner::class)`.
 */
abstract class FileSaverTestBase {
    protected val context: Application = ApplicationProvider.getApplicationContext()
    protected lateinit var mediaStore: FakeMediaStoreProvider
    protected lateinit var fileSaver: FileSaver

    /** Exceptions that reached a thread's uncaught-exception handler, i.e. would crash the app. */
    private val uncaught = Collections.synchronizedList(mutableListOf<Throwable>())
    private var previousHandler: Thread.UncaughtExceptionHandler? = null

    @Before
    fun setUpFileSaver() {
        previousHandler = Thread.getDefaultUncaughtExceptionHandler()
        Thread.setDefaultUncaughtExceptionHandler { _, e -> uncaught += e }
        FileSaver.appContext = context
        mediaStore = FakeMediaStoreProvider.install()
        fileSaver = FileSaver()
    }

    @After
    fun tearDownFileSaver() {
        Thread.setDefaultUncaughtExceptionHandler(previousHandler)
        FileSaver.appContext = null
        FileSaver.storagePermissionHandler = null
    }

    protected fun assertNoCrash() {
        // Give a crashing coroutine time to reach the handler.
        Thread.sleep(100)
        assertTrue("Uncaught exceptions: $uncaught", uncaught.isEmpty())
    }

    /** Runs [FileSaver.saveBytes] and returns the callback once a terminal event arrived. */
    protected fun saveBytes(
        data: ByteArray,
        fileName: String,
        extension: String,
        mimeType: String,
        location: SaveLocation,
        subDir: String? = "probe",
        conflictResolution: ConflictResolution = ConflictResolution.AUTO_RENAME,
    ): RecordingCallback {
        val callback = RecordingCallback()
        fileSaver.saveBytes(data, fileName, extension, mimeType, location.ordinal, subDir, conflictResolution.value, callback)
        callback.awaitTerminal()
        return callback
    }

    protected fun openWriteSession(
        fileName: String,
        extension: String,
        mimeType: String,
        location: SaveLocation,
        callback: RecordingCallback,
        subDir: String? = "probe",
    ) = fileSaver.openWriteSession(
        fileName,
        extension,
        mimeType,
        location.ordinal,
        subDir,
        ConflictResolution.AUTO_RENAME.value,
        -1,
        callback,
    )
}
