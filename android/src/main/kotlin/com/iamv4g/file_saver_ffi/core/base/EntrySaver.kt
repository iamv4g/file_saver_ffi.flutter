package com.iamv4g.file_saver_ffi.core.base

import android.content.Context
import com.iamv4g.file_saver_ffi.exception.NetworkDownloadException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.ErrorCode
import com.iamv4g.file_saver_ffi.models.SaveProgressEvent
import com.iamv4g.file_saver_ffi.utils.FileHelper
import com.iamv4g.file_saver_ffi.utils.NetworkHelper
import com.iamv4g.file_saver_ffi.utils.ioErrorCode
import com.iamv4g.file_saver_ffi.utils.saveFlow
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.flow.Flow
import java.io.FileNotFoundException
import java.io.IOException

/**
 * Saves bytes, a file or a download to the entry of a [SaveEntryFactory]
 * (MediaStore or SAF), for files of every type. Each flow asks [SaveEntryFactory.createEntry] for the
 * target: [SaveEntry.Existing] (SKIP) completes immediately with the existing
 * file, and [SaveEntry.Created] is written and then committed by
 * [SaveEntryFactory.finishSave]. A failed or cancelled write deletes only the
 * new entry, never the file it would replace.
 */
class EntrySaver(
    private val context: Context,
) {
    /**
     * Saves byte array data with real-time progress streaming.
     *
     * @param fileData File data to save
     * @param entryFactory Factory for creating save entry (MediaStore or SAF)
     * @param conflictResolution Strategy for handling existing files
     */
    fun saveBytes(
        fileData: ByteArray,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {
            if (fileData.isEmpty()) {
                sendError(ErrorCode.INVALID_INPUT, "File data cannot be empty")
                return@saveFlow
            }

            val entry =
                when (val result = entryFactory.createEntry(this, context, conflictResolution)) {
                    null -> return@saveFlow
                    is SaveEntry.Existing -> {
                        sendExisting(result)
                        return@saveFlow
                    }
                    is SaveEntry.Created -> result
                }

            try {
                FileHelper.writeStream(entry.outputStream, fileData) { bytesWritten ->
                    sendProgress(bytesWritten, fileData.size.toLong())
                }
            } catch (e: CancellationException) {
                entryFactory.deleteEntry(context, entry.uri)
                throw e
            } catch (e: IOException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendError(ioErrorCode(e), "Failed to write file data: ${e.message}")
                return@saveFlow
            } catch (e: Exception) {
                // Anything else (e.g. a SecurityException from a revoked grant):
                // remove the new entry, then let saveFlow report it.
                entryFactory.deleteEntry(context, entry.uri)
                throw e
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
    fun saveFile(
        filePath: String,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {

            val sourceFile =
                try {
                    FileHelper.openSourceFile(context, filePath)
                } catch (_: FileNotFoundException) {
                    sendError(ErrorCode.FILE_NOT_FOUND, filePath)
                    return@saveFlow
                } catch (e: SecurityException) {
                    sendError(ErrorCode.PERMISSION_DENIED, "Permission denied: ${e.message}")
                    return@saveFlow
                } catch (e: IllegalArgumentException) {
                    sendError(ErrorCode.INVALID_INPUT, e.message ?: "Invalid file path")
                    return@saveFlow
                }

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

            try {
                FileHelper.copyStream(sourceFile.inputStream, entry.outputStream, sourceFile.totalSize) { bytesWritten ->
                    sendProgress(bytesWritten, sourceFile.totalSize)
                }
            } catch (e: CancellationException) {
                entryFactory.deleteEntry(context, entry.uri)
                throw e
            } catch (e: IOException) {
                entryFactory.deleteEntry(context, entry.uri)
                sendError(ioErrorCode(e), "Failed to copy file: ${e.message}")
                return@saveFlow
            } catch (e: Exception) {
                entryFactory.deleteEntry(context, entry.uri)
                throw e
            }

            entryFactory.finishSave(this, context, entry)
        }

    /**
     * Downloads file from network URL and saves directly with real-time progress.
     *
     * @param url Network URL to download from
     * @param headersJson Optional JSON string of HTTP headers
     * @param timeoutMs Timeout in milliseconds for connecting and for each read
     * @param entryFactory Factory for creating save entry (MediaStore or SAF)
     * @param conflictResolution Strategy for handling existing files
     */
    fun saveNetwork(
        url: String,
        headersJson: String?,
        timeoutMs: Int,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        saveFlow {

            try {
                NetworkHelper.download(url, headersJson, timeoutMs) { response ->

                    val entry =
                        when (val result = entryFactory.createEntry(this, context, conflictResolution)) {
                            null -> return@download
                            is SaveEntry.Existing -> {
                                sendExisting(result)
                                return@download
                            }
                            is SaveEntry.Created -> result
                        }

                    try {
                        val totalSize = response.contentLength.takeIf { it >= 0 }
                        FileHelper.copyStream(response.body, entry.outputStream, totalSize) { bytesWritten ->
                            sendProgress(bytesWritten, totalSize)
                        }
                    } catch (e: CancellationException) {
                        entryFactory.deleteEntry(context, entry.uri)
                                throw e
                    } catch (e: NetworkDownloadException) {
                        // Reading the body failed: reported as a network error below.
                        entryFactory.deleteEntry(context, entry.uri)
                        throw e
                    } catch (e: IOException) {
                        entryFactory.deleteEntry(context, entry.uri)
                        sendError(ioErrorCode(e), "Failed to write the downloaded data: ${e.message}")
                        return@download
                    } catch (e: Exception) {
                        entryFactory.deleteEntry(context, entry.uri)
                        throw e
                    }

                    entryFactory.finishSave(this, context, entry)
                }
            } catch (e: NetworkDownloadException) {
                sendError(ErrorCode.NETWORK_ERROR, e.message ?: "Download failed", e.statusCode)
            } catch (e: IllegalArgumentException) {
                sendError(ErrorCode.INVALID_INPUT, e.message ?: "Invalid request headers")
            }
        }
}
