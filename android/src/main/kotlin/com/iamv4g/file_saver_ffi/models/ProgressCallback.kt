package com.iamv4g.file_saver_ffi.models

/**
 * Callback interface for reporting async operation results from native Kotlin to Dart via JNI.
 *
 * ## Message protocol
 *
 * ### Used by `save()` / `saveAs()`
 * | eventType | progress         | data       | message |
 * |-----------|------------------|------------|---------|
 * | 0         | –                | –          | –       | Started
 * | 1         | 0.0–1.0 fraction | –          | –       | Progress
 * | 2         | –                | errorCode  | msg     | Error
 * | 3         | –                | fileUri    | –       | Success
 * | 4         | –                | –          | –       | Cancelled
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
     * @param progress  For save: 0.0–1.0 fraction. For write-session chunk/flush ACK: cumulative bytes written.
     * @param data      eventType=2 → errorCode; eventType=3 → fileUri or sessionId string
     * @param message   eventType=2 → human-readable error message; otherwise null
     */
    fun onEvent(
        eventType: Int,
        progress: Double,
        data: String?,
        message: String?,
    )
}
