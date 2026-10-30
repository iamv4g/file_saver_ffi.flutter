package com.iamv4g.file_saver_ffi.utils

import com.iamv4g.file_saver_ffi.models.FileType

/**
 * Validates file types for saving operations.
 *
 * Note: This library is a file saver, not a media player.
 * We only validate that the MIME type category matches the expected type.
 * The developer is responsible for choosing the appropriate format.
 * Files are written as raw bytes - no encoding/decoding is performed.
 */
object FormatValidator {
    /**
     * Validates image format.
     * Only checks that the MIME type is an image type.
     */
    fun validateImageFormat(fileType: FileType) {
        if (fileType.category != FileType.Category.IMAGE) {
            throw IllegalStateException("Expected image MIME type")
        }
    }

    /**
     * Validates video format.
     * Only checks that the MIME type is a video type.
     */
    fun validateVideoFormat(fileType: FileType) {
        if (fileType.category != FileType.Category.VIDEO) {
            throw IllegalStateException("Expected video MIME type")
        }
    }

    /**
     * Validates audio format.
     * Only checks that the MIME type is an audio type.
     */
    fun validateAudioFormat(fileType: FileType) {
        if (fileType.category != FileType.Category.AUDIO) {
            throw IllegalStateException("Expected audio MIME type")
        }
    }
}
