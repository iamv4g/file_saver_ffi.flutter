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
     * @property value Progress value from 0.0 to 1.0
     */
    data class Progress(
        val value: Double,
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
     * @property message Error message
     */
    data class Error(
        val code: String,
        val message: String,
    ) : SaveProgressEvent()

    /**
     * User cancelled the operation.
     */
    data object Cancelled : SaveProgressEvent()
}
