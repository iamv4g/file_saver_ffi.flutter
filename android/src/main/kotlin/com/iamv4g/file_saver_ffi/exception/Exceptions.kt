package com.iamv4g.file_saver_ffi.exception

import java.io.IOException

/**
 * Exception thrown when file already exists and conflict mode is FAIL
 *
 * @property fileName Name of the existing file, which is also the message
 */
class FileExistsException(
    val fileName: String,
) : Exception(fileName)

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
 * @property code One of the error codes in [com.iamv4g.file_saver_ffi.utils.Constants]
 */
class FileOpenException(
    val code: String,
    message: String,
    cause: Throwable? = null,
) : Exception(message, cause)
