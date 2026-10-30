package com.iamv4g.file_saver_ffi.models

data class FileType(
    var ext: String,
    var mimeType: String,
) {
    init {
        ext = ext.lowercase()
        mimeType = mimeType.lowercase()
    }

    enum class Category {
        IMAGE,
        VIDEO,
        AUDIO,
        CUSTOM,
    }

    val category: Category
        get() =
            when {
                mimeType.startsWith("image/") -> Category.IMAGE
                mimeType.startsWith("video/") -> Category.VIDEO
                mimeType.startsWith("audio/") -> Category.AUDIO
                else -> Category.CUSTOM
            }

    val isImage get() = category == Category.IMAGE
    val isVideo get() = category == Category.VIDEO
    val isAudio get() = category == Category.AUDIO
}
