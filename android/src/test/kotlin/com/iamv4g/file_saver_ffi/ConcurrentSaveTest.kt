package com.iamv4g.file_saver_ffi

import android.Manifest
import android.content.Intent
import android.net.Uri
import android.os.Environment
import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.ErrorCode
import com.iamv4g.file_saver_ffi.models.SaveLocation
import com.iamv4g.file_saver_ffi.testing.Event
import com.iamv4g.file_saver_ffi.testing.FakeDocumentsProvider
import com.iamv4g.file_saver_ffi.testing.FileSaverTestBase
import com.iamv4g.file_saver_ffi.testing.RecordingCallback
import com.iamv4g.file_saver_ffi.utils.LegacyStoreConflictResolver
import kotlinx.coroutines.runBlocking
import org.junit.Assert.assertArrayEquals
import org.junit.Assert.assertEquals
import org.junit.Assert.assertTrue
import org.junit.Before
import org.junit.Test
import org.junit.runner.RunWith
import org.robolectric.RobolectricTestRunner
import org.robolectric.Shadows.shadowOf
import org.robolectric.annotation.Config
import java.io.File

/**
 * Saves of one name started at the same time, as when a save button is
 * tapped several times quickly. Each must end with a name of its own and its
 * whole content, and the conflict modes must hold across them.
 *
 * The fake providers wait a little before creating an entry, so that every
 * save picks its name before any of them has created one, unless the plugin
 * makes them take turns.
 */
@RunWith(RobolectricTestRunner::class)
@Config(sdk = [34])
class ConcurrentSaveTest : FileSaverTestBase() {
    private val dir = "Download/probe/"
    private val count = 5

    @Before
    fun widenRace() {
        mediaStore.beforeInsert = { Thread.sleep(50) }
    }

    /** One save's content and its terminal event. */
    private class Save(
        val data: ByteArray,
        val event: Event,
    ) {
        val succeeded get() = event.type == 3
        val uri: Uri get() = Uri.parse(event.data)
    }

    /**
     * Starts [count] saves of `leg.txt` at once with [start], the i-th with
     * the content `[i]`, and waits for them.
     */
    private fun concurrently(start: (data: ByteArray, callback: RecordingCallback) -> Unit): List<Save> =
        (1..count)
            .map { i -> byteArrayOf(i.toByte()).let { data -> data to RecordingCallback().also { start(data, it) } } }
            .map { (data, callback) -> Save(data, callback.awaitTerminal(10_000)) }

    private fun saveBytesConcurrently(mode: ConflictResolution) =
        concurrently { data, callback ->
            fileSaver.saveBytes(data, "leg", "txt", "text/plain", SaveLocation.DOWNLOADS.ordinal, "probe", mode.ordinal, callback)
        }

    private fun rowsInDir() = mediaStore.rows.values.filter { it.relativePath == dir }

    /** Every save succeeded, with a row of its own that holds its content, and none is left pending. */
    private fun assertEachSavedItsOwnFile(saves: List<Save>) {
        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        assertEquals(saves.map { it.uri }.toString(), count, saves.map { it.uri }.toSet().size)
        saves.forEach { assertArrayEquals("Content of ${it.uri}", it.data, mediaStore.contentOf(it.uri)) }
        val names = rowsInDir().map { it.displayName }
        assertEquals(names.toString(), names.size, names.toSet().size)
        assertTrue(rowsInDir().none { it.isPending })
    }

    @Test
    fun `autoRename gives each save a name and file of its own`() {
        mediaStore.addExisting("leg.txt", dir)

        val saves = saveBytesConcurrently(ConflictResolution.AUTO_RENAME)

        assertEachSavedItsOwnFile(saves)
        assertEquals(
            (listOf("leg.txt") + (1..count).map { "leg ($it).txt" }).toSet(),
            rowsInDir().map { it.displayName }.toSet(),
        )
    }

    @Test
    fun `autoRename into an empty directory gives each save a file of its own`() {
        assertEachSavedItsOwnFile(saveBytesConcurrently(ConflictResolution.AUTO_RENAME))
        assertEquals(count, rowsInDir().size)
    }

    @Test
    fun `fail lets exactly one save create the file`() {
        val saves = saveBytesConcurrently(ConflictResolution.FAIL)

        val saved = saves.single { it.succeeded }
        saves.filterNot { it.succeeded }.forEach {
            assertEquals("Event: ${it.event}", 2, it.event.type)
            assertEquals(ErrorCode.FILE_EXISTS, it.event.data)
        }
        assertEquals(listOf("leg.txt"), rowsInDir().map { it.displayName })
        assertArrayEquals(saved.data, mediaStore.contentOf(saved.uri))
    }

    @Test
    fun `skip lets exactly one save create the file, and the others report it`() {
        val saves = saveBytesConcurrently(ConflictResolution.SKIP)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        val row = rowsInDir().single()
        assertEquals("leg.txt", row.displayName)
        saves.forEach { assertEquals(row.id, it.uri.lastPathSegment!!.toLong()) }
    }

    @Test
    fun `overwrite ends with one file, holding the content of one save`() {
        mediaStore.addExisting("leg.txt", dir)

        val saves = saveBytesConcurrently(ConflictResolution.OVERWRITE)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        val row = rowsInDir().single()
        assertEquals("leg.txt", row.displayName)
        assertTrue(saves.any { it.data.contentEquals(row.file.readBytes()) })
    }

    @Test
    fun `overwrite into an empty directory ends with one file`() {
        val saves = saveBytesConcurrently(ConflictResolution.OVERWRITE)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        val row = rowsInDir().single()
        assertEquals("leg.txt", row.displayName)
        assertTrue(saves.any { it.data.contentEquals(row.file.readBytes()) })
    }

    @Test
    fun `overwrite keeps the new file numbered while another save writes the name`() {
        // A save that isn't an overwrite holds the name, still pending.
        val open = RecordingCallback()
        openWriteSession("leg", "txt", "text/plain", SaveLocation.DOWNLOADS, open)
        assertEquals("Events: ${open.events}", 3, open.awaitTerminal().type)

        val save = saveBytes(byteArrayOf(9), "leg", "txt", "text/plain", SaveLocation.DOWNLOADS, conflictResolution = ConflictResolution.OVERWRITE)

        assertEquals("Events: ${save.events}", 3, save.awaitTerminal().type)
        assertEquals(setOf("leg.txt", "leg (1).txt"), rowsInDir().map { it.displayName }.toSet())
        assertTrue(rowsInDir().single { it.displayName == "leg.txt" }.isPending)
    }

    @Test
    fun `write sessions get a name and file of their own`() {
        mediaStore.addExisting("leg.txt", dir)

        // Opens them all at once, then writes and closes each.
        val opens =
            (1..count).map {
                RecordingCallback().also { open -> openWriteSession("leg", "txt", "text/plain", SaveLocation.DOWNLOADS, open) }
            }
        val saves =
            opens.mapIndexed { i, open ->
                val data = byteArrayOf((i + 1).toByte())
                val sessionId = open.awaitTerminal(10_000).data!!.toLong()
                RecordingCallback().also { fileSaver.writeChunk(sessionId, data, it) }.awaitEvents(1)
                val close = RecordingCallback().also { fileSaver.closeSession(sessionId, it) }
                Save(data, close.awaitTerminal(10_000))
            }

        assertEachSavedItsOwnFile(saves)
    }

    // ── Android 10 ─────────────────────────────────────────────────────────

    @Test
    @Config(sdk = [29])
    fun `on Android 10 a row that is still being written counts as taken`() {
        // Android 10 leaves pending rows out of a query unless asked.
        val open = RecordingCallback()
        openWriteSession("leg", "txt", "text/plain", SaveLocation.DOWNLOADS, open)
        assertEquals("Events: ${open.events}", 3, open.awaitTerminal().type)

        val fail = saveBytes(byteArrayOf(1), "leg", "txt", "text/plain", SaveLocation.DOWNLOADS, conflictResolution = ConflictResolution.FAIL)
        val rename = saveBytes(byteArrayOf(2), "leg", "txt", "text/plain", SaveLocation.DOWNLOADS, conflictResolution = ConflictResolution.AUTO_RENAME)

        assertEquals(ErrorCode.FILE_EXISTS, fail.awaitTerminal().data)
        assertEquals(3, rename.awaitTerminal().type)
        assertEquals(setOf("leg.txt", "leg (1).txt"), rowsInDir().map { it.displayName }.toSet())
    }

    @Test
    @Config(sdk = [29])
    fun `on Android 10 fail lets exactly one save create the file`() {
        val saves = saveBytesConcurrently(ConflictResolution.FAIL)

        assertEquals(saves.map { it.event }.toString(), 1, saves.count { it.succeeded })
        assertEquals(listOf("leg.txt"), rowsInDir().map { it.displayName })
    }

    // ── Android 9 and below ────────────────────────────────────────────────

    private fun legacyDir() =
        File(Environment.getExternalStoragePublicDirectory(Environment.DIRECTORY_DOWNLOADS), "probe").apply { mkdirs() }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 the resolver claims the name it picks`() {
        val directory = legacyDir()
        File(directory, "leg.txt").writeBytes(byteArrayOf(0))

        // Without writing in between, as when two saves resolve at once.
        val picked =
            runBlocking {
                (1..count).map {
                    LegacyStoreConflictResolver.resolve(directory, "leg", "txt", ConflictResolution.AUTO_RENAME)
                }
            }.map { (it as LegacyStoreConflictResolver.Resolution.Create).file.name }

        assertEquals((1..count).map { "leg ($it).txt" }, picked)
    }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 fail lets only the first of two resolves create the file`() {
        val directory = legacyDir()

        runBlocking {
            LegacyStoreConflictResolver.resolve(directory, "leg", "txt", ConflictResolution.FAIL)
            try {
                LegacyStoreConflictResolver.resolve(directory, "leg", "txt", ConflictResolution.FAIL)
                throw AssertionError("The second resolve didn't fail")
            } catch (_: FileExistsException) {
            }
        }
    }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 concurrent saves each get a file of their own`() {
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        File(legacyDir(), "leg.txt").writeBytes(byteArrayOf(0))

        val saves = saveBytesConcurrently(ConflictResolution.AUTO_RENAME)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        assertEquals(count, saves.map { it.uri }.toSet().size)
        saves.forEach { assertArrayEquals(it.data, File(it.uri.path!!).readBytes()) }
    }

    @Test
    @Config(sdk = [28])
    fun `on Android 9 overwrite ends with one file, holding the content of one save`() {
        shadowOf(context).grantPermissions(Manifest.permission.WRITE_EXTERNAL_STORAGE)
        val directory = legacyDir()
        File(directory, "leg.txt").writeBytes(byteArrayOf(0))

        val saves = saveBytesConcurrently(ConflictResolution.OVERWRITE)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        assertEquals(listOf("leg.txt"), directory.list()!!.toList())
        val content = File(directory, "leg.txt").readBytes()
        assertTrue(saves.any { it.data.contentEquals(content) })
    }

    // ── Storage Access Framework ───────────────────────────────────────────

    private fun installDocuments() =
        FakeDocumentsProvider.install().also {
            context.grantUriPermission(
                context.packageName,
                it.treeUri,
                Intent.FLAG_GRANT_READ_URI_PERMISSION or Intent.FLAG_GRANT_WRITE_URI_PERMISSION,
            )
            it.beforeCreateDocument = { Thread.sleep(50) }
        }

    private fun saveAsConcurrently(
        documents: FakeDocumentsProvider,
        mode: ConflictResolution,
    ) = concurrently { data, callback ->
        fileSaver.saveBytesAs(data, documents.treeUri.toString(), "leg", "txt", "text/plain", mode.ordinal, callback)
    }

    @Test
    fun `in a picked directory autoRename gives each save the next number`() {
        val documents = installDocuments()
        documents.addExisting("leg.txt")

        val saves = saveAsConcurrently(documents, ConflictResolution.AUTO_RENAME)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        assertEquals((listOf("leg.txt") + (1..count).map { "leg ($it).txt" }).toSet(), documents.names().toSet())
    }

    @Test
    fun `in a picked directory fail lets exactly one save create the file`() {
        val documents = installDocuments()

        val saves = saveAsConcurrently(documents, ConflictResolution.FAIL)

        assertEquals(saves.map { it.event }.toString(), 1, saves.count { it.succeeded })
        assertEquals(listOf("leg.txt"), documents.names())
    }

    @Test
    fun `in a picked directory overwrite ends with one file, holding the content of one save`() {
        val documents = installDocuments()
        documents.addExisting("leg.txt")

        val saves = saveAsConcurrently(documents, ConflictResolution.OVERWRITE)

        saves.forEach { assertEquals("Event: ${it.event}", 3, it.event.type) }
        assertEquals(listOf("leg.txt"), documents.names())
        val content = documents.contentOf("leg.txt")!!
        assertTrue(saves.any { it.data.contentEquals(content) })
    }

    @Test
    fun `in a picked directory that can't rename, overwrite of a new name writes under the name`() {
        val documents = installDocuments()
        documents.supportsRename = false

        val save =
            RecordingCallback().also {
                fileSaver.saveBytesAs(byteArrayOf(4), documents.treeUri.toString(), "leg", "txt", "text/plain", ConflictResolution.OVERWRITE.ordinal, it)
            }

        assertEquals("Events: ${save.events}", 3, save.awaitTerminal().type)
        assertEquals(listOf("leg.txt"), documents.names())
        assertArrayEquals(byteArrayOf(4), documents.contentOf("leg.txt"))
    }

    @Test
    fun `in a picked directory that can't rename, overwrite of a taken name keeps both files`() {
        val documents = installDocuments()
        documents.supportsRename = false
        documents.addExisting("leg.txt")

        val save =
            RecordingCallback().also {
                fileSaver.saveBytesAs(byteArrayOf(4), documents.treeUri.toString(), "leg", "txt", "text/plain", ConflictResolution.OVERWRITE.ordinal, it)
            }

        val event = save.awaitTerminal()
        assertEquals("Events: ${save.events}", 3, event.type)
        assertEquals(setOf("leg.txt", "leg (1).txt"), documents.names().toSet())
        assertArrayEquals(byteArrayOf(4), documents.contentOf("leg (1).txt"))
    }
}
