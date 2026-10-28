package com.vanvixi.file_saver_ffi.core.base

import com.vanvixi.file_saver_ffi.models.SaveProgressEvent
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

/**
 * Sends a progress event.
 */
internal fun ProducerScope<SaveProgressEvent>.sendProgress(progress: Double) {
    trySend(SaveProgressEvent.Progress(progress))
}

/**
 * Sends an error event.
 */
internal fun ProducerScope<SaveProgressEvent>.sendError(
    code: String,
    message: String,
) {
    trySend(SaveProgressEvent.Error(code, message))
}

/**
 * Sends a cancelled event.
 */
internal fun ProducerScope<SaveProgressEvent>.sendCancelled() {
    trySend(SaveProgressEvent.Cancelled)
}

/**
 * Sends a success event.
 */
internal fun ProducerScope<SaveProgressEvent>.sendSuccess(uri: String) {
    trySend(SaveProgressEvent.Success(uri))
}

/**
 * Completes a save that was skipped because the file already exists
 * ([com.vanvixi.file_saver_ffi.models.ConflictResolution.SKIP]): reports the
 * existing file without writing anything.
 */
internal fun ProducerScope<SaveProgressEvent>.sendExisting(entry: SaveEntry.Existing) {
    sendProgress(1.0)
    sendSuccess(entry.uri.toString())
}
