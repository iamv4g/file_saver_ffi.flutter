package com.vanvixi.file_saver_ffi

import android.Manifest
import android.content.Context
import android.content.pm.PackageManager
import android.os.Build
import android.util.Log
import androidx.core.content.ContextCompat
import androidx.core.net.toUri
import com.vanvixi.file_saver_ffi.core.AudioSaver
import com.vanvixi.file_saver_ffi.core.CustomFileSaver
import com.vanvixi.file_saver_ffi.core.ImageSaver
import com.vanvixi.file_saver_ffi.core.VideoSaver
import com.vanvixi.file_saver_ffi.core.base.BaseFileSaver
import com.vanvixi.file_saver_ffi.core.base.SaveEntryFactory
import com.vanvixi.file_saver_ffi.exception.FileOpenException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import com.vanvixi.file_saver_ffi.models.ProgressCallback
import com.vanvixi.file_saver_ffi.models.SaveLocation
import com.vanvixi.file_saver_ffi.models.SaveProgressEvent
import com.vanvixi.file_saver_ffi.utils.Constants
import com.vanvixi.file_saver_ffi.utils.FileOpener
import com.vanvixi.file_saver_ffi.utils.StoragePermissionHandler
import com.vanvixi.file_saver_ffi.utils.WriteSessionManager
import kotlinx.coroutines.CoroutineExceptionHandler
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.Job
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.catch
import kotlinx.coroutines.flow.emitAll
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn
import kotlinx.coroutines.job
import kotlinx.coroutines.launch
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicLong

/**
 * @param engineId Id of the Flutter engine whose Dart side creates this
 *   instance (`PlatformDispatcher.engineId`), or -1 if there is none, as in a
 *   background isolate. The saves and write sessions of an instance with an
 *   engine are cancelled when that engine is destroyed.
 */
class FileSaver(
    engineId: Long,
) {
    private val context: Context
        get() = appContext ?: error("FileSaver not initialized. FileSaverFfiPlugin must be attached first.")
    private val imageSaver get() = ImageSaver(context)
    private val videoSaver get() = VideoSaver(context)
    private val audioSaver get() = AudioSaver(context)
    private val customFileSaver get() = CustomFileSaver(context)

    /**
     * Runs every save and write-session coroutine. [SupervisorJob] keeps one
     * failed operation from cancelling the others, and the handler logs an
     * exception that escapes an operation instead of crashing the app.
     */
    private val scope =
        CoroutineScope(
            SupervisorJob() + Dispatchers.IO +
                CoroutineExceptionHandler { _, e -> Log.e(TAG, "Unhandled error in save operation", e) },
        )

    private val activeJobs = ConcurrentHashMap<Long, Job>()
    private val operationIdCounter = AtomicLong(0)
    private val sessionManager = WriteSessionManager(scope)

    init {
        FileSaverFfiPlugin.trackSaver(this, engineId)
    }

    companion object {
        private const val TAG = "FileSaverFfi"

        /**
         * Application context stored by [FileSaverFfiPlugin.onAttachedToEngine].
         * Must be set before any [FileSaver] instance is used. Never cleared,
         * because every engine in the process shares it.
         */
        @Volatile
        internal var appContext: Context? = null

        /**
         * Static permission handler set by [FileSaverFfiPlugin.onAttachedToEngine].
         *
         * Bridges [FileSaver] (created via JNI without Context) to the plugin layer
         * (which has Activity access for showing permission dialogs). It asks in
         * the Activity of any attached engine.
         */
        @Volatile
        var storagePermissionHandler: StoragePermissionHandler? = null
    }

    /**
     * Cancels every save and write session of this instance, deleting their
     * partial files. Called when the engine that created it is destroyed, so
     * no Dart code is left to receive their events.
     */
    internal fun dispose() {
        scope.cancel()
        appContext?.let { sessionManager.discardAll(it, scope.coroutineContext.job) }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // File opening
    // ─────────────────────────────────────────────────────────────────────────

    // Both run on [scope] rather than on the caller's thread, which is the
    // main thread when Dart calls in: they make blocking IPC calls.

    /**
     * Checks whether the file at [uri] can be read.
     *
     * Reports `callback(3, 1.0, "true" | "false", null)`, or
     * `callback(2, 0.0, code, message)` if the check couldn't run.
     */
    fun canOpenFile(
        uri: String,
        callback: ProgressCallback,
    ) {
        scope.launch {
            try {
                callback.onEvent(3, 1.0, FileOpener.canOpenFile(context, uri).toString(), null)
            } catch (e: Exception) {
                callback.onEvent(2, 0.0, Constants.ERROR_PLATFORM, e.message)
            }
        }
    }

    /**
     * Opens the file at [uri] with a system app (see [FileOpener.openFile]).
     *
     * Reports `callback(3, 1.0, null, null)` once the app was started, or
     * `callback(2, 0.0, code, message)` with the code from [FileOpenException].
     */
    fun openFile(
        uri: String,
        mimeType: String?,
        callback: ProgressCallback,
    ) {
        scope.launch {
            try {
                FileOpener.openFile(context, uri, mimeType)
                callback.onEvent(3, 1.0, null, null)
            } catch (e: FileOpenException) {
                callback.onEvent(2, 0.0, e.code, e.message)
            } catch (e: Exception) {
                callback.onEvent(2, 0.0, Constants.ERROR_PLATFORM, e.message)
            }
        }
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Operation management
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Cancels an ongoing save operation.
     *
     * @param operationId The operation ID returned by saveBytes, saveFile, or saveNetwork
     */
    fun cancelOperation(operationId: Long) {
        activeJobs[operationId]?.cancel()
    }

    // ─────────────────────────────────────────────────────────────────────────
    // Save to MediaStore
    // ─────────────────────────────────────────────────────────────────────────

    fun saveBytes(
        fileData: ByteArray,
        baseFileName: String,
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        subDir: String?,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            mediaStoreFlow(extension, mimeType, saveLocationIndex, baseFileName, subDir, conflictMode) { saver, ef, cr ->
                saver.saveBytes(fileData, ef, cr)
            },
        )

    fun saveFile(
        filePath: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        subDir: String?,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            mediaStoreFlow(extension, mimeType, saveLocationIndex, baseFileName, subDir, conflictMode) { saver, ef, cr ->
                saver.saveFile(filePath, ef, cr)
            },
        )

    fun saveNetwork(
        url: String,
        headersJson: String?,
        timeoutMs: Int,
        baseFileName: String,
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        subDir: String?,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            mediaStoreFlow(extension, mimeType, saveLocationIndex, baseFileName, subDir, conflictMode) { saver, ef, cr ->
                saver.saveNetwork(url, headersJson, timeoutMs, ef, cr)
            },
        )

    // ─────────────────────────────────────────────────────────────────────────
    // Save to SAF (user-selected directory)
    // ─────────────────────────────────────────────────────────────────────────

    fun saveBytesAs(
        fileData: ByteArray,
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            safFlow(directoryUri, baseFileName, extension, mimeType, conflictMode) { ef, cr ->
                customFileSaver.saveBytes(fileData, ef, cr)
            },
        )

    fun saveFileAs(
        filePath: String,
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            safFlow(directoryUri, baseFileName, extension, mimeType, conflictMode) { ef, cr ->
                customFileSaver.saveFile(filePath, ef, cr)
            },
        )

    fun saveNetworkAs(
        url: String,
        headersJson: String?,
        timeoutMs: Int,
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        callback: ProgressCallback,
    ): Long =
        launchWithCallback(
            callback,
            safFlow(directoryUri, baseFileName, extension, mimeType, conflictMode) { ef, cr ->
                customFileSaver.saveNetwork(url, headersJson, timeoutMs, ef, cr)
            },
        )

    // ─────────────────────────────────────────────────────────────────────────
    // Streaming write sessions
    // ─────────────────────────────────────────────────────────────────────────

    fun openWriteSession(
        baseFileName: String,
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        subDir: String?,
        conflictMode: Int,
        totalSize: Long,
        callback: ProgressCallback,
    ) = sessionManager.openWriteSession(
        context,
        baseFileName,
        extension,
        mimeType,
        saveLocationIndex,
        subDir,
        conflictMode,
        totalSize,
        callback,
        ensureStoragePermission = { ensureStoragePermission() },
    )

    fun openWriteSessionAs(
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        totalSize: Long,
        callback: ProgressCallback,
    ) = sessionManager.openWriteSessionAs(
        context,
        directoryUri,
        baseFileName,
        extension,
        mimeType,
        conflictMode,
        totalSize,
        callback,
    )

    fun writeChunk(
        sessionId: Long,
        data: ByteArray,
        callback: ProgressCallback,
    ) = sessionManager.writeChunk(sessionId, data, callback)

    fun flushSession(
        sessionId: Long,
        callback: ProgressCallback,
    ) = sessionManager.flushSession(sessionId, callback)

    fun closeSession(
        sessionId: Long,
        callback: ProgressCallback,
    ) = sessionManager.closeSession(context, sessionId, callback)

    fun cancelSession(sessionId: Long) = sessionManager.cancelSession(context, sessionId)

    // ─────────────────────────────────────────────────────────────────────────
    // Private helpers
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Builds a Flow for MediaStore saves: handles permission check, type/location
     * resolution, entry factory creation, and error mapping.
     *
     * Errors are mapped by [reportErrors].
     */
    private fun mediaStoreFlow(
        extension: String,
        mimeType: String,
        saveLocationIndex: Int,
        baseFileName: String,
        subDir: String?,
        conflictMode: Int,
        save: (BaseFileSaver, SaveEntryFactory, ConflictResolution) -> Flow<SaveProgressEvent>,
    ): Flow<SaveProgressEvent> =
        flow {
            ensureStoragePermission()

            val fileType = FileType(extension, mimeType)
            val conflictResolution = ConflictResolution.fromInt(conflictMode)
            val saveLocation = SaveLocation.fromInt(saveLocationIndex)
            val saver = getSaverForFileType(fileType)
            val entryFactory =
                SaveEntryFactory.MediaStore(
                    fileType = fileType,
                    baseFileName = baseFileName,
                    saveLocation = saveLocation,
                    subDir = subDir,
                )

            emitAll(save(saver, entryFactory, conflictResolution))
        }.reportErrors().flowOn(Dispatchers.IO)

    /**
     * Builds a Flow for SAF saves: wraps SAF entry factory creation and delegates to [save].
     *
     * Nothing runs until the flow is collected, so a failure is reported as an
     * error event instead of being thrown across JNI.
     */
    private fun safFlow(
        directoryUri: String,
        baseFileName: String,
        extension: String,
        mimeType: String,
        conflictMode: Int,
        save: (SaveEntryFactory, ConflictResolution) -> Flow<SaveProgressEvent>,
    ): Flow<SaveProgressEvent> =
        flow {
            val entryFactory =
                SaveEntryFactory.SAF(
                    treeUri = directoryUri.toUri(),
                    fileType = FileType(extension, mimeType),
                    baseFileName = baseFileName,
                )
            emitAll(save(entryFactory, ConflictResolution.fromInt(conflictMode)))
        }.reportErrors()

    /**
     * Turns an exception from upstream into an error event.
     *
     * [catch] only sees upstream exceptions, so a failure in the collector is
     * not re-emitted into the flow and cancellation is not reported as an error.
     */
    private fun Flow<SaveProgressEvent>.reportErrors(): Flow<SaveProgressEvent> =
        catch { e ->
            when (e) {
                is SecurityException ->
                    emit(SaveProgressEvent.Error(Constants.ERROR_PERMISSION_DENIED, "Permission denied: ${e.message}"))
                is Exception ->
                    emit(SaveProgressEvent.Error(Constants.ERROR_PLATFORM, "Unexpected error: ${e.message ?: "Unknown error"}"))
                else -> throw e
            }
        }

    /**
     * Ensures WRITE_EXTERNAL_STORAGE permission is granted on API < 29.
     *
     * - API 29+: Returns immediately (scoped storage, no permission needed)
     * - API < 29 with permission granted: Returns immediately
     * - API < 29 without permission: Requests via [storagePermissionHandler]
     *
     * @throws SecurityException if permission is denied or handler is unavailable
     */
    internal suspend fun ensureStoragePermission() {
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q) return

        val status = ContextCompat.checkSelfPermission(context, Manifest.permission.WRITE_EXTERNAL_STORAGE)
        if (status == PackageManager.PERMISSION_GRANTED) return

        val handler =
            storagePermissionHandler
                ?: throw SecurityException("Storage permission required but no Activity available to request it")

        if (!handler.requestStoragePermission()) {
            throw SecurityException("Storage permission denied by user")
        }
    }

    private fun getSaverForFileType(fileType: FileType): BaseFileSaver =
        when {
            fileType.isImage -> imageSaver
            fileType.isVideo -> videoSaver
            fileType.isAudio -> audioSaver
            else -> customFileSaver
        }

    private fun launchWithCallback(
        callback: ProgressCallback,
        flow: Flow<SaveProgressEvent>,
    ): Long {
        val operationId = operationIdCounter.incrementAndGet()
        val job =
            scope.launch {
                flow.collect { event ->
                    when (event) {
                        is SaveProgressEvent.Started -> callback.onEvent(0, 0.0, null, null)
                        is SaveProgressEvent.Progress -> callback.onEvent(1, event.value, null, null)
                        is SaveProgressEvent.Error -> callback.onEvent(2, 0.0, event.code, event.message)
                        is SaveProgressEvent.Success -> callback.onEvent(3, 1.0, event.uri, null)
                        is SaveProgressEvent.Cancelled -> callback.onEvent(4, 0.0, null, null)
                    }
                }
            }
        activeJobs[operationId] = job
        job.invokeOnCompletion { activeJobs.remove(operationId) }
        return operationId
    }
}
