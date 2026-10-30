package com.iamv4g.file_saver_ffi.models

/**
 * Represents save locations for files on Android.
 *
 * Maps to MediaStore collections and storage directories.
 */
enum class SaveLocation {
    /** MediaStore.Images.Media (Pictures/ directory) */
    PICTURES,

    /** MediaStore.Video.Media (Movies/ directory) */
    MOVIES,

    /** MediaStore.Audio.Media (Music/ directory) */
    MUSIC,

    /** MediaStore.Downloads (Downloads/ directory) - Default */
    DOWNLOADS,

    /** MediaStore.Images.Media (DCIM/ directory - camera photos) */
    DCIM,

    ;

    companion object {
        /**
         * Converts an integer index to SaveLocation enum.
         *
         * @param value The index from Dart enum (0-4)
         * @return Corresponding SaveLocation, defaults to DOWNLOADS if invalid
         */
        fun fromInt(value: Int): SaveLocation = entries.getOrNull(value) ?: DOWNLOADS
    }
}
