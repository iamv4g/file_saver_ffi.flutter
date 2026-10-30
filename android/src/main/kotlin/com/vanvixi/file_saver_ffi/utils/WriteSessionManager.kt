package com.vanvixi.file_saver_ffi.utils

import android.content.Context
import android.util.Log
import androidx.core.net.toUri
import com.vanvixi.file_saver_ffi.core.base.SaveEntry
import com.vanvixi.file_saver_ffi.core.base.SaveEntryFactory
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import com.vanvixi.file_saver_ffi.models.ProgressCallback
import com.vanvixi.file_saver_ffi.models.SaveLocation
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.launch
import java.io.IOException
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * @param scope Scope for all session work. It must use a `SupervisorJob` and a
 *   `CoroutineExceptionHandler`, so one failing session cannot cancel the
 *   others or crash the app.
 */
internal class WriteSessionManager(
    private val scope: CoroutineScope,
) {
    private companion object {
        const val TAG = "FileSaverFfi"
    }

    private data class WriteSession(
        val entry: SaveEntry.Created,
        val entryFactory: SaveEntryFactory,
        val totalSize: Long, // -1 if unknown
        val sessionScope: CoroutineScope, // limited(1) → guarantees chunk ordering
        var bytesWritten: Long = 0L,
        // The first write or flush error. Later calls report it again, and
        // close deletes the entry instead of publishing a truncated file.
        var failure: Failure? = null,
    )

    private data class Failure(
        val code: String,
        val message: String?,
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
        scope.launch {
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
            } catch (e: Exception) {
                reportError(callback, e)
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
        scope.launch {
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
            } catch (e: Exception) {
                reportError(callback, e)
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
                val sessionScope = CoroutineScope(scope.coroutineContext + Dispatchers.IO.limitedParallelism(1))
                writeSessions[sessionId] = WriteSession(entry, entryFactory, totalSize, sessionScope)
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
            session.failure?.let { return@launch callback.onEvent(2, 0.0, it.code, it.message) }
            try {
                session.entry.outputStream.write(data)
                session.bytesWritten += data.size
                callback.onEvent(1, session.bytesWritten.toDouble(), null, null)
            } catch (e: Exception) {
                session.failure = failureOf(e)
                reportError(callback, e)
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
            session.failure?.let { return@launch callback.onEvent(2, 0.0, it.code, it.message) }
            try {
                session.entry.outputStream.flush()
                callback.onEvent(1, session.bytesWritten.toDouble(), null, null)
            } catch (e: Exception) {
                session.failure = failureOf(e)
                reportError(callback, e)
            }
        }
    }

    /**
     * Closes and finalizes an open write session.
     *
     * For MediaStore entries, marks the file as complete (removes IS_PENDING flag).
     * If a write or flush failed, deletes the new entry and reports that error.
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
            // Only the new entry is removed; a file being overwritten stays intact.
            session.failure?.let { failure ->
                try {
                    session.entry.outputStream.close()
                } catch (_: Exception) {
                }
                session.entryFactory.deleteEntry(context, session.entry.uri)
                return@launch callback.onEvent(2, 0.0, failure.code, failure.message)
            }
            try {
                session.entry.outputStream.close()
                val uri = session.entryFactory.commitEntry(context, session.entry)
                callback.onEvent(3, 1.0, uri.toString(), null)
            } catch (e: Exception) {
                session.entryFactory.deleteEntry(context, session.entry.uri)
                reportError(callback, e)
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

    /**
     * Removes every open session and deletes its partial file, once [scope]'s
     * work (including chunk writes in progress) has ended. No callback.
     *
     * @param scopeJob The job of [scope], already cancelled. The cleanup runs
     *   outside [scope] for that reason.
     */
    fun discardAll(
        context: Context,
        scopeJob: Job,
    ) {
        val sessions = writeSessions.values.toList()
        writeSessions.clear()
        if (sessions.isEmpty()) return

        CoroutineScope(Dispatchers.IO + CoroutineExceptionHandler { _, e -> Log.e(TAG, "Failed to discard write sessions", e) })
            .launch {
                scopeJob.join()
                sessions.forEach { session ->
                    try {
                        session.entry.outputStream.close()
                    } catch (_: Exception) {
                    }
                    session.entryFactory.deleteEntry(context, session.entry.uri)
                }
            }
    }

    /**
     * Reports [e] through [callback] with the matching error code.
     *
     * Rethrows [CancellationException] so the coroutine still ends as cancelled.
     */
    private fun reportError(
        callback: ProgressCallback,
        e: Exception,
    ) {
        val failure = failureOf(e)
        callback.onEvent(2, 0.0, failure.code, failure.message)
    }

    /** The error code and message for [e]. Rethrows [CancellationException]. */
    private fun failureOf(e: Exception): Failure {
        val code =
            when (e) {
                is CancellationException -> throw e
                is FileExistsException -> Constants.ERROR_FILE_EXISTS
                is IOException -> Constants.ERROR_FILE_IO
                is SecurityException -> Constants.ERROR_PERMISSION_DENIED
                // A non-tree SAF URI, or a MIME type the MediaStore collection rejects.
                is IllegalArgumentException -> Constants.ERROR_INVALID_INPUT
                else -> Constants.ERROR_PLATFORM
            }
        return Failure(code, e.message)
    }
}
