package com.iamv4g.file_saver_ffi.core.base

import com.iamv4g.file_saver_ffi.models.SaveProgressEvent
import kotlinx.coroutines.channels.ProducerScope

// ─────────────────────────────────────────────────────────────────────────────
// Event Sending Extensions
// ─────────────────────────────────────────────────────────────────────────────

// Every event uses the suspending send, so none is dropped: the Dart stream
// ends only with a terminal event (Error, Success), and the last progress
// event carries the size of the file. FileHelper throttles progress events.

/**
 * Sends a progress event: [bytesWritten] of [totalBytes], which is null if
 * the size isn't known.
 */
internal suspend fun ProducerScope<SaveProgressEvent>.sendProgress(
    bytesWritten: Long,
    totalBytes: Long?,
) {
    send(SaveProgressEvent.Progress(bytesWritten, totalBytes))
}

/**
 * Sends an error event.
 */
internal suspend fun ProducerScope<SaveProgressEvent>.sendError(
    code: String,
    message: String,
    statusCode: Int? = null,
) {
    send(SaveProgressEvent.Error(code, message, statusCode))
}

/**
 * Sends a success event.
 */
internal suspend fun ProducerScope<SaveProgressEvent>.sendSuccess(uri: String) {
    send(SaveProgressEvent.Success(uri))
}

/**
 * Completes a save that was skipped because the file already exists
 * ([com.iamv4g.file_saver_ffi.models.ConflictResolution.SKIP]): reports the
 * existing file without writing anything.
 */
internal suspend fun ProducerScope<SaveProgressEvent>.sendExisting(entry: SaveEntry.Existing) {
    sendSuccess(entry.uri.toString())
}
