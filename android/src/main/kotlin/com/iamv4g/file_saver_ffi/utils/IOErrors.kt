package com.iamv4g.file_saver_ffi.utils

import android.system.ErrnoException
import android.system.OsConstants
import com.iamv4g.file_saver_ffi.models.ErrorCode
import java.io.IOException

/**
 * The error code for a failed read or write: [ErrorCode.STORAGE_FULL]
 * when the device ran out of space (ENOSPC, or EDQUOT for a full quota),
 * otherwise [ErrorCode.FILE_IO_ERROR].
 *
 * A failed write reports the errno as the [ErrnoException] cause of an
 * [IOException]. A provider's stream may only keep it in the message, as
 * "write failed: ENOSPC (No space left on device)".
 */
internal fun ioErrorCode(e: Throwable): String {
    var cause: Throwable? = e
    while (cause != null) {
        if (cause is ErrnoException && (cause.errno == OsConstants.ENOSPC || cause.errno == OsConstants.EDQUOT)) {
            return ErrorCode.STORAGE_FULL
        }
        val message = cause.message.orEmpty()
        if ("ENOSPC" in message || "EDQUOT" in message || "No space left on device" in message) {
            return ErrorCode.STORAGE_FULL
        }
        cause = cause.cause.takeIf { it !== cause }
    }
    return ErrorCode.FILE_IO_ERROR
}
