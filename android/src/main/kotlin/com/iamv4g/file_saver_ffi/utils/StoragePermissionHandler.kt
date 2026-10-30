package com.iamv4g.file_saver_ffi.utils

/**
 * Bridge interface for requesting WRITE_EXTERNAL_STORAGE permission.
 *
 * Connects [FileSaver][com.iamv4g.file_saver_ffi.FileSaver] (which only has Context, created via JNI)
 * to the plugin layer (which has Activity access via ActivityAware).
 *
 * Only called on API < 29 where WRITE_EXTERNAL_STORAGE is required for legacy storage.
 */
fun interface StoragePermissionHandler {
    /**
     * Requests WRITE_EXTERNAL_STORAGE permission.
     *
     * Implementation must switch to Main thread to show the permission dialog,
     * suspend until the user responds, and return the result.
     *
     * @return true if permission was granted, false if denied
     */
    suspend fun requestStoragePermission(): Boolean
}
