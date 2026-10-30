package com.iamv4g.file_saver_ffi.core.base

import android.net.Uri
import java.io.OutputStream

/**
 * Target of a save, as resolved by [SaveEntryFactory] for a
 * [com.iamv4g.file_saver_ffi.models.ConflictResolution].
 */
sealed class SaveEntry {
    /**
     * A new entry to write the content to.
     *
     * It only becomes the saved file once [SaveEntryFactory.commitEntry]
     * succeeds. Until then [replaces] is left untouched, so a failed or
     * cancelled write never loses the file being overwritten.
     *
     * @param uri URI of the new entry (a temporary file for legacy overwrites)
     * @param outputStream Stream to write the content to
     * @param replaces Existing file to replace on commit (OVERWRITE only)
     */
    class Created(
        val uri: Uri,
        val outputStream: OutputStream,
        val replaces: Uri? = null,
    ) : SaveEntry()

    /**
     * The target file already exists and SKIP was requested: nothing is written,
     * and the save reports [uri] as its result.
     */
    class Existing(
        val uri: Uri,
    ) : SaveEntry()
}
