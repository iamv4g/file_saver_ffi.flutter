package com.vanvixi.file_saver_ffi.exception

import java.io.IOException

/**
 * Exception thrown when a file format is not supported on the current device
 *
 * @property format The unsupported file format (e.g., "HEIC", "MKV")
 * @property message Detailed error message explaining why the format is not supported
 */
class UnsupportedFormatException(
    val format: String,
    message: String,
) : Exception(message)

/**
 * Exception thrown when file already exists and conflict mode is FAIL
 *
 * @property message Error message with file details
 */
class FileExistsException(
    message: String,
) : Exception(message)

/**
 * Exception thrown when a network download fails.
 */
class NetworkDownloadException(
    message: String,
    val statusCode: Int? = null,
) : IOException(message)

/**
 * Exception thrown when a saved file cannot be opened.
 *
 * @property code One of the error codes in [com.vanvixi.file_saver_ffi.utils.Constants]
 */
class FileOpenException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
