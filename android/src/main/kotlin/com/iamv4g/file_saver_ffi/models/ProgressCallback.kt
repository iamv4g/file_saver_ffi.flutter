package com.iamv4g.file_saver_ffi.models

/**
 * Callback interface for reporting async operation results from native Kotlin to Dart via JNI.
 *
 * ## Message protocol
 *
 * ### Used by `save()` / `saveAs()`
 * | eventType | progress         | data          | message |
 * |-----------|------------------|---------------|---------|
 * | 0         | –                | –             | –       | Started
 * | 1         | bytesWritten     | totalBytes    | –       | Progress
 * | 2         | HTTP status or 0 | errorCode     | detail  | Error
 * | 3         | –                | fileUri       | –       | Success
 * | 4         | –                | –             | –       | Cancelled
 *
 * Progress sends the bytes of the file written so far, and the size of the
 * file as a decimal string, or null if it isn't known (a download without
 * `Content-Length`, many `content://` sources). `copyToPath` reports the same.
 *
 * An error sends the HTTP status of a [com.iamv4g.file_saver_ffi.utils.Constants.ERROR_NETWORK]
 * error as `progress`, and 0 otherwise. Its `message` is the detail the Dart
 * exception for the code needs (see `FileSaverErrorCode` in Dart), such as
 * just the file name for `FILE_EXISTS` or the path for `FILE_NOT_FOUND`.
 *
 * Cancelled (4) is sent only after `FileSaver.cancelOperation`, once the save
 * has stopped and deleted what it wrote, and isn't sent after `dispose()`.
 *
 * ### Used by write-session methods (`openWriteSession`, `writeChunk`, `flushSession`, `closeSession`)
 * | eventType | progress          | data               | message |
 * |-----------|-------------------|--------------------|---------|
 * | 1         | bytesWritten      | –                  | –       | Chunk / flush ACK
 * | 2         | –                 | errorCode          | msg     | Error
 * | 3         | –                 | sessionId (open)   | –       | Session opened
 * | 3         | –                 | fileUri (close)    | –       | Session closed / finalized
 */
interface ProgressCallback {
    /**
     * Called for each event.
     *
     * @param eventType 0=Started, 1=Progress/ChunkAck, 2=Error, 3=Success/SessionEvent, 4=Cancelled
     * @param progress  eventType=1 → cumulative bytes written, for a save as for a write-session chunk/flush ACK.
     *                  eventType=2 → HTTP status of a network error, otherwise 0.
     * @param data      eventType=1 → the save's size, if known; eventType=2 → errorCode;
     *                  eventType=3 → fileUri or sessionId string
     * @param message   eventType=2 → the error detail; otherwise null
     */
    fun onEvent(
        eventType: Int,
        progress: Double,
        data: String?,
        message: String?,
    )
}
