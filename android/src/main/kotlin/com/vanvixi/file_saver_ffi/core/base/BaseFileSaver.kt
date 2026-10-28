package com.vanvixi.file_saver_ffi.core.base

import android.content.Context
import com.vanvixi.file_saver_ffi.exception.NetworkDownloadException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.SaveProgressEvent
import com.vanvixi.file_saver_ffi.utils.Constants
import com.vanvixi.file_saver_ffi.utils.FileHelper
import com.vanvixi.file_saver_ffi.utils.NetworkHelper
import com.vanvixi.file_saver_ffi.utils.saveFlow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Shared save flows. Each one asks [SaveEntryFactory.createEntry] for the
 * target: [SaveEntry.Existing] (SKIP) completes immediately with the existing
 * file, and [SaveEntry.Created] is written and then committed by
 * [SaveEntryFactory.finishSave]. A failed or cancelled write deletes only the
 * new entry, never the file it would replace.
 */
abstract class BaseFileSaver(
    protected val context: Context,
) {
    /**
     * Saves byte array data with real-time progress streaming.
     *
     * @param fileData File data to save
     * @param entryFactory Factory for creating save entry (MediaStore or SAF)
     * @param conflictResolution Strategy for handling existing files
     */
    open fun saveBytes(
        fileData: ByteArray,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {
            if (fileData.isEmpty()) {
                sendError(Constants.ERROR_INVALID_INPUT, "File data cannot be empty")
                return@saveFlow
            }

            sendProgress(0.05)

            val entry =
                when (val result = entryFactory.createEntry(this, context, conflictResolution)) {
                    null -> return@saveFlow
                    is SaveEntry.Existing -> {
                        sendExisting(result)
                        return@saveFlow
                    }
                    is SaveEntry.Created -> result
                }

            sendProgress(0.1)

            try {
                FileHelper.writeStream(entry.outputStream, fileData) { writeProgress ->
                    sendProgress(mapProgress(writeProgress, 0.1, 0.9))
                }
            } catch (e: CancellationException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendCancelled()
                throw e
            } catch (e: IOException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendError(Constants.ERROR_FILE_IO, "Failed to write file data: ${e.message}")
                return@saveFlow
            }

            entryFactory.finishSave(this, context, entry)
        }

    /**
     * Saves file from source path with real-time progress streaming.
     *
     * @param filePath Source file path (file:// or content:// URI)
     * @param entryFactory Factory for creating save entry (MediaStore or SAF)
     * @param conflictResolution Strategy for handling existing files
     */
    open fun saveFile(
        filePath: String,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {
            sendProgress(0.05)

            val sourceFile =
                try {
                    FileHelper.openSourceFile(context, filePath)
                } catch (_: FileNotFoundException) {
                    sendError(Constants.ERROR_FILE_NOT_FOUND, "Source file not found: $filePath")
                    return@saveFlow
                } catch (e: SecurityException) {
                    sendError(Constants.ERROR_PERMISSION_DENIED, "Permission denied: ${e.message}")
                    return@saveFlow
                } catch (e: IllegalArgumentException) {
                    sendError(Constants.ERROR_INVALID_INPUT, e.message ?: "Invalid file path")
                    return@saveFlow
                }

            sendProgress(0.1)

            val entry =
                when (val result = entryFactory.createEntry(this, context, conflictResolution)) {
                    null -> {
                        sourceFile.inputStream.close()
                        return@saveFlow
                    }
                    is SaveEntry.Existing -> {
                        sourceFile.inputStream.close()
                        sendExisting(result)
                        return@saveFlow
                    }
                    is SaveEntry.Created -> result
                }

            sendProgress(0.15)

            try {
                FileHelper.copyStream(sourceFile.inputStream, entry.outputStream, sourceFile.totalSize) { copyProgress ->
                    sendProgress(mapProgress(copyProgress, 0.15, 0.9))
                }
            } catch (e: CancellationException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendCancelled()
                throw e
            } catch (e: IOException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendError(Constants.ERROR_FILE_IO, "Failed to copy file: ${e.message}")
                return@saveFlow
            }

            entryFactory.finishSave(this, context, entry)
        }

    /**
     * Downloads file from network URL and saves directly with real-time progress.
     *
     * @param url Network URL to download from
     * @param headersJson Optional JSON string of HTTP headers
     * @param timeoutMs Connection timeout in milliseconds
     * @param entryFactory Factory for creating save entry (MediaStore or SAF)
     * @param conflictResolution Strategy for handling existing files
     */
    open fun saveNetwork(
        url: String,
        headersJson: String?,
        timeoutMs: Int,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {
            sendProgress(0.02)

            val connectionResult =
                try {
                    NetworkHelper.openConnection(url, headersJson, timeoutMs)
                } catch (e: NetworkDownloadException) {
                    val message =
                        if (e.statusCode != null) {
                            "Network download failed (HTTP ${e.statusCode}): ${e.message}"
                        } else {
                            "Network download failed: ${e.message}"
                        }
                    sendError(Constants.ERROR_NETWORK, message)
                    return@saveFlow
                }

            try {
                sendProgress(0.05)

                val entry =
                    when (val result = entryFactory.createEntry(this, context, conflictResolution)) {
                        null -> return@saveFlow
                        is SaveEntry.Existing -> {
                            sendExisting(result)
                            return@saveFlow
                        }
                        is SaveEntry.Created -> result
                    }

                sendProgress(0.1)

                try {
                    FileHelper.copyStream(
                        connectionResult.inputStream,
                        entry.outputStream,
                        connectionResult.contentLength,
                    ) { copyProgress ->
                        sendProgress(mapProgress(copyProgress, 0.1, 0.9))
                    }
                } catch (e: CancellationException) {
                    entryFactory.deleteEntry(context, entry.uri)
                    sendCancelled()
                    throw e
                } catch (e: IOException) {
                    entryFactory.deleteEntry(context, entry.uri)
                    sendError(Constants.ERROR_FILE_IO, "Failed to stream network data: ${e.message}")
                    return@saveFlow
                }

                entryFactory.finishSave(this, context, entry)
            } finally {
                try {
                    connectionResult.connection.disconnect()
                } catch (_: Exception) {
                }
            }
        }
}
