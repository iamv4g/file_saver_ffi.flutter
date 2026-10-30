package com.iamv4g.file_saver_ffi.utils

object Constants {
    // ===========================================
    // Error Codes
    // ===========================================

    /**
     * Invalid input (empty data, malformed URI, invalid file path)
     */
    const val ERROR_INVALID_INPUT = "INVALID_INPUT"

    /**
     * Storage permission denied by user
     */
    const val ERROR_PERMISSION_DENIED = "PERMISSION_DENIED"

    /**
     * File format not supported on this Android version
     * Example: HEIC/HEIF on Android 9 and below
     */
    const val ERROR_UNSUPPORTED_FORMAT = "UNSUPPORTED_FORMAT"

    /**
     * Insufficient storage space available
     */
    const val ERROR_STORAGE_FULL = "STORAGE_FULL"

    /**
     * File already exists and conflict mode is FAIL
     */
    const val ERROR_FILE_EXISTS = "FILE_EXISTS"

    /**
     * File I/O error (read/write failed)
     */
    const val ERROR_FILE_IO = "FILE_IO_ERROR"

    /**
     * Source file not found
     */
    const val ERROR_FILE_NOT_FOUND = "FILE_NOT_FOUND"

    /**
     * A saved file could not be opened (no app for it, missing FileProvider setup)
     */
    const val ERROR_OPEN_FAILED = "OPEN_FAILED"

    /**
     * Generic platform error
     */
    const val ERROR_PLATFORM = "PLATFORM_ERROR"

    /**
     * Network download error (HTTP error, timeout, connection failed)
     */
    const val ERROR_NETWORK = "NETWORK_ERROR"

    /**
     * Operation was cancelled by user
     */
    const val ERROR_CANCELLED = "CANCELLED"

    /**
     * Chunk size for file writing: 1MB
     * Used to split large files into manageable chunks
     */
    const val CHUNK_SIZE = 1024 * 1024 // 1MB
}
