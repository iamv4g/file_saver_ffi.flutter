package com.iamv4g.file_saver_ffi.core.base

import com.iamv4g.file_saver_ffi.models.SaveProgressEvent
import kotlinx.coroutines.channels.ProducerScope

/**
 * Maps progress from source range [0.0-1.0] to target range [start-end].
 */
internal fun mapProgress(
    progress: Double,
    start: Double,
    end: Double,
): Double = start + (progress * (end - start))

// ─────────────────────────────────────────────────────────────────────────────
// Event Sending Extensions
// ─────────────────────────────────────────────────────────────────────────────

// Progress events use trySend and may be dropped when the buffer is full; a
// later progress event replaces them. Terminal events (Error, Success) use the
// suspending send so they are never dropped, otherwise the Dart stream would
// never end.

/**
 * Sends a progress event.
 */
internal fun ProducerScope<SaveProgressEvent>.sendProgress(progress: Double) {
    trySend(SaveProgressEvent.Progress(progress))
}

/**
 * Sends an error event.
 */
internal suspend fun ProducerScope<SaveProgressEvent>.sendError(
    code: String,
    message: String,
) {
    send(SaveProgressEvent.Error(code, message))
}

/**
 * Sends a cancelled event.
 *
 * Best effort: the caller is already cancelled, so a suspending send would
 * throw. The Dart side ends the stream on cancel anyway.
 */
internal fun ProducerScope<SaveProgressEvent>.sendCancelled() {
    trySend(SaveProgressEvent.Cancelled)
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
    sendProgress(1.0)
    sendSuccess(entry.uri.toString())
}
