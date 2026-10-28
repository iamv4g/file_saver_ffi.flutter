package com.vanvixi.file_saver_ffi.utils

import android.content.Context
import androidx.core.net.toUri
import com.vanvixi.file_saver_ffi.core.base.SaveEntry
import com.vanvixi.file_saver_ffi.core.base.SaveEntryFactory
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import com.vanvixi.file_saver_ffi.models.ProgressCallback
import com.vanvixi.file_saver_ffi.models.SaveLocation
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

internal class WriteSessionManager {
    private data class WriteSession(
        val entry: SaveEntry.Created,
        val entryFactory: SaveEntryFactory,
        val totalSize: Long, // -1 if unknown
        val sessionScope: CoroutineScope, // limited(1) → guarantees chunk ordering
        var bytesWritten: Long = 0L,
    )

    private val writeSessions = ConcurrentHashMap<Long, WriteSession>()
    private val sessionIdCounter = AtomicLong(0)

    /**
     * Opens a streaming write session to a MediaStore location.
     *
     * On success: callback(3, 0.0, sessionId, null)
     * On error:   callback(2, 0.0, errorCode, message)
     */
    fun openWriteSession(
        context: Context,
        baseFileName: String,
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        subDir: String?,
        conflictMode: Int,
        totalSize: Long,
        callback: ProgressCallback,
        ensureStoragePermission: suspend () -> Unit,
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                ensureStoragePermission()
                val fileType = FileType(extension, mimeType)
                val conflictResolution = ConflictResolution.fromInt(conflictMode)
                val saveLocation = SaveLocation.fromInt(saveLocationIndex)

                val entryFactory =
                    SaveEntryFactory.MediaStore(
                        fileType = fileType,
                        baseFileName = baseFileName,
                        saveLocation = saveLocation,
                        subDir = subDir,
                    )
                startSession(context, entryFactory, conflictResolution, totalSize, callback)
            } catch (e: FileExistsException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_EXISTS, e.message)
            } catch (e: IOException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_IO, e.message)
            } catch (e: SecurityException) {
                callback.onEvent(2, 0.0, Constants.ERROR_PERMISSION_DENIED, e.message)
            }
        }
    }

    /**
     * Opens a streaming write session to a user-selected SAF directory.
     *
     * On success: callback(3, 0.0, sessionId, null)
     * On error:   callback(2, 0.0, errorCode, message)
     */
    fun openWriteSessionAs(
        context: Context,
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        totalSize: Long,
        callback: ProgressCallback,
    ) {
        CoroutineScope(Dispatchers.IO).launch {
            try {
                val fileType = FileType(extension, mimeType)
                val conflictResolution = ConflictResolution.fromInt(conflictMode)

                val entryFactory =
                    SaveEntryFactory.SAF(
                        treeUri = directoryUri.toUri(),
                        fileType = fileType,
                        baseFileName = baseFileName,
                    )
                startSession(context, entryFactory, conflictResolution, totalSize, callback)
            } catch (e: FileExistsException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_EXISTS, e.message)
            } catch (e: IOException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_IO, e.message)
            }
        }
    }

    /**
     * Resolves the target through [entryFactory] and registers a session for it.
     *
     * SKIP with an existing file reports `callback(3, 0.0, "0", existingUri)`
     * (session id 0 means "no session"), and nothing is written.
     */
    private suspend fun startSession(
        context: Context,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
        totalSize: Long,
        callback: ProgressCallback,
    ) {
        when (val entry = entryFactory.createEntryDirect(context, conflictResolution)) {
            is SaveEntry.Existing -> {
                callback.onEvent(3, 0.0, "0", entry.uri.toString())
            }

            is SaveEntry.Created -> {
                val sessionId = sessionIdCounter.incrementAndGet()
                val scope = CoroutineScope(Dispatchers.IO.limitedParallelism(1))
                writeSessions[sessionId] = WriteSession(entry, entryFactory, totalSize, scope)
                callback.onEvent(3, 0.0, sessionId.toString(), null)
            }
        }
    }

    /**
     * Writes a chunk of data to an open write session.
     *
     * On success: callback(1, bytesWritten, null, null)
     * On error:   callback(2, 0.0, errorCode, message)
     */
    fun writeChunk(
        sessionId: Long,
        data: ByteArray,
        callback: ProgressCallback,
    ) {
        val session =
            writeSessions[sessionId]
                ?: return callback.onEvent(2, 0.0, Constants.ERROR_INVALID_INPUT, "Session not found: $sessionId")

        session.sessionScope.launch {
            try {
                session.entry.outputStream.write(data)
                session.bytesWritten += data.size
                callback.onEvent(1, session.bytesWritten.toDouble(), null, null)
            } catch (e: IOException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_IO, e.message)
            }
        }
    }

    /**
     * Flushes buffered data to storage for an open write session.
     *
     * On success: callback(1, bytesWritten, null, null)
     * On error:   callback(2, 0.0, errorCode, message)
     */
    fun flushSession(
        sessionId: Long,
        callback: ProgressCallback,
    ) {
        val session =
            writeSessions[sessionId]
                ?: return callback.onEvent(2, 0.0, Constants.ERROR_INVALID_INPUT, "Session not found: $sessionId")

        session.sessionScope.launch {
            try {
                session.entry.outputStream.flush()
                callback.onEvent(1, session.bytesWritten.toDouble(), null, null)
            } catch (e: IOException) {
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_IO, e.message)
            }
        }
    }

    /**
     * Closes and finalizes an open write session.
     *
     * For MediaStore entries, marks the file as complete (removes IS_PENDING flag).
     * On success: callback(3, 1.0, uri, null)
     * On error:   callback(2, 0.0, errorCode, message)
     */
    fun closeSession(
        context: Context,
        sessionId: Long,
        callback: ProgressCallback,
    ) {
        val session =
            writeSessions.remove(sessionId)
                ?: return callback.onEvent(2, 0.0, Constants.ERROR_INVALID_INPUT, "Session not found: $sessionId")

        session.sessionScope.launch {
            try {
                session.entry.outputStream.close()
                val uri = session.entryFactory.commitEntry(context, session.entry)
                callback.onEvent(3, 1.0, uri.toString(), null)
            } catch (e: Exception) {
                // Only the new entry is removed; a file being overwritten stays intact.
                session.entryFactory.deleteEntry(context, session.entry.uri)
                callback.onEvent(2, 0.0, Constants.ERROR_FILE_IO, e.message)
            }
        }
    }

    /**
     * Cancels a write session — closes the stream and deletes the partial file.
     * Fire-and-forget: no callback.
     */
    fun cancelSession(
        context: Context,
        sessionId: Long,
    ) {
        val session = writeSessions.remove(sessionId) ?: return
        session.sessionScope.launch {
            try {
                session.entry.outputStream.close()
            } catch (_: Exception) {
            }
            session.entryFactory.deleteEntry(context, session.entry.uri)
        }
    }
}
