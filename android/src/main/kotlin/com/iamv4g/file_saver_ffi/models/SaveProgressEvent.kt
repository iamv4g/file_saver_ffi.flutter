package com.iamv4g.file_saver_ffi.models

/**
 * Sealed class representing save progress events.
 *
 * Used to stream progress updates from native code to Dart via JNI/Flow.
 */
sealed class SaveProgressEvent {
    /**
     * Emitted when save operation starts.
     */
    data object Started : SaveProgressEvent()

    /**
     * Progress update during save operation.
     *
     * @property bytesWritten Bytes of the file written so far
     * @property totalBytes The size of the file, or null if it isn't known
     */
    data class Progress(
        val bytesWritten: Long,
        val totalBytes: Long?,
    ) : SaveProgressEvent()

    /**
     * Save completed successfully.
     *
     * @property uri URI of the saved file
     */
    data class Success(
        val uri: String,
    ) : SaveProgressEvent()

    /**
     * Save failed with error.
     *
     * @property code Error code
     * @property message The detail the Dart side expects for [code]
     * @property statusCode HTTP status of a network error
     */
    data class Error(
        val code: String,
        val message: String,
        val statusCode: Int? = null,
    ) : SaveProgressEvent()
}
