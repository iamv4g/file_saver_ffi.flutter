package com.iamv4g.file_saver_ffi.models

enum class ConflictResolution(
    val value: Int,
) {
    /**
     * Automatically rename file with (1), (2), (3) suffix pattern
     * Example: file.txt → file (1).txt → file (2).txt
     */
    AUTO_RENAME(0),

    /**
     * Overwrite existing file
     *
     * Platform behavior:
     * - Android 9 and below: Full overwrite capability (requires WRITE_EXTERNAL_STORAGE)
     * - Android 10+: Only overwrites files owned by this app
     *
     * Platform limitation (Android 10+):
     * Due to Scoped Storage, files from other apps cannot be detected.
     * If a file with the same name exists from another app, MediaStore will
     * automatically rename your file instead (e.g., photo.jpg → photo (1).jpg)
     *
     * iOS behavior:
     * - Photos: Own files are overwritten; other apps' files create duplicates
     * - Documents: Full overwrite (each app has isolated sandbox)
     *
     * WARNING: When successful, existing file will be permanently deleted
     */
    OVERWRITE(1),

    /**
     * Fail operation if file exists
     * Returns error code: FILE_EXISTS
     */
    FAIL(2),

    /**
     * Skip operation silently if file exists
     * Returns success with existing file path
     */
    SKIP(3),
    ;

    companion object {
        /**
         * Converts integer value to ConflictResolution
         *
         * @param value Integer value (0-3)
         * @return Corresponding ConflictResolution, defaults to AUTO_RENAME if invalid
         */
        fun fromInt(value: Int): ConflictResolution = entries.find { it.value == value } ?: AUTO_RENAME
    }
}
