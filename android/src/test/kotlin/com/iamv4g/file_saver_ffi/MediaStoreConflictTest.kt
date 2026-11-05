package com.iamv4g.file_saver_ffi

import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.FakeMediaStoreProvider
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.annotation.Config

/**
 * Name conflicts in a MediaStore directory (Android 10+), where
 * [FakeMediaStoreProvider] numbers a taken name only up to `name (31)`, as
 * MediaProvider does.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class MediaStoreConflictTest : FileSaverTestBase() {
    private val dir = "Download/probe/"

    /** `limit.txt` and `limit (1).txt` … `limit (count - 1).txt` in [dir]. */
    private fun addCopies(count: Int) {
        mediaStore.addExisting("limit.txt", dir)
        (1 until count).forEach { mediaStore.addExisting("limit ($it).txt", dir) }
    }

    private fun save(
        conflictResolution: ConflictResolution,
        data: ByteArray = byteArrayOf(7),
    ) = saveBytes(data, "limit", "txt", "text/plain", SaveLocation.DOWNLOADS, conflictResolution = conflictResolution)
        .awaitTerminal()

    private fun rowsInDir() = mediaStore.rows.values.filter { it.relativePath == dir }

    private fun namesInDir() = rowsInDir().map { it.displayName }

    private fun contentOf(name: String) = rowsInDir().single { it.displayName == name }.file.readBytes()

    @Test
    fun `autoRename picks the first free number itself`() {
        mediaStore.addExisting("limit.txt", dir)
        mediaStore.addExisting("limit (2).txt", dir)
        // The same name elsewhere doesn't count.
        mediaStore.addExisting("limit (1).txt", "Download/other/")

        val event = save(ConflictResolution.AUTO_RENAME)

        assertEquals("Event: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(7), contentOf("limit (1).txt"))
    }

    @Test
    fun `autoRename keeps numbering after the 32 names MediaProvider tries`() {
        addCopies(FakeMediaStoreProvider.MAX_UNIQUE_NAMES)

        val event = save(ConflictResolution.AUTO_RENAME)

        assertEquals("Event: $event", 3, event.type)
        assertArrayEquals(byteArrayOf(7), contentOf("limit (32).txt"))
    }

    @Test
    fun `overwrite replaces the file however many numbered copies exist`() {
        addCopies(FakeMediaStoreProvider.MAX_UNIQUE_NAMES)

        val event = save(ConflictResolution.OVERWRITE, byteArrayOf(5, 6))

        assertEquals("Event: $event", 3, event.type)
        val names = namesInDir()
        assertEquals(names.toString(), FakeMediaStoreProvider.MAX_UNIQUE_NAMES, names.size)
        assertEquals(names.toString(), 1, names.count { it == "limit.txt" })
        assertArrayEquals(byteArrayOf(5, 6), contentOf("limit.txt"))
    }
}
