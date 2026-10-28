package com.vanvixi.file_saver_ffi.utils

import com.vanvixi.file_saver_ffi.models.SaveProgressEvent
import kotlinx.coroutines.CancellationException
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.channels.awaitClose
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.callbackFlow
import kotlinx.coroutines.flow.flowOn

/**
 * Creates a Flow for save operations that emit SaveProgressEvent.
 *
 * Handles common patterns:
 * - Emits Started event at the beginning
 * - Catches CancellationException and emits Cancelled event
 * - Catches SecurityException and emits Error with permission denied code
 * - Catches generic Exception and emits Error with platform error code
 * - Sends terminal events with the suspending send, so they are never dropped
 * - Properly closes the flow and awaits close
 * - Runs on IO dispatcher
 *
 * Usage:
 * ```kotlin
 * fun saveBytes(...): Flow<SaveProgressEvent> = saveFlow {
 *     // Business logic only - no boilerplate needed
 *     trySend(SaveProgressEvent.Progress(0.05))
 *     // ... do work ...
 *     send(SaveProgressEvent.Success(uri.toString()))
 * }
 * ```
 */
inline fun saveFlow(crossinline block: suspend ProducerScope<SaveProgressEvent>.() -> Unit): Flow<SaveProgressEvent> =
    callbackFlow {
        trySend(SaveProgressEvent.Started)
        try {
            block()
        } catch (e: CancellationException) {
            trySend(SaveProgressEvent.Cancelled)
            close()
            awaitClose {}
            throw e // Re-throw to properly cancel coroutine
        } catch (e: SecurityException) {
            send(
                SaveProgressEvent.Error(
                    Constants.ERROR_PERMISSION_DENIED,
                    "Permission denied: ${e.message}",
                ),
            )
        } catch (e: Exception) {
            send(
                SaveProgressEvent.Error(
                    Constants.ERROR_PLATFORM,
                    "Unexpected error: ${e.message ?: "Unknown error"}",
                ),
            )
        }
        close()
        awaitClose {}
    }.flowOn(Dispatchers.IO)
