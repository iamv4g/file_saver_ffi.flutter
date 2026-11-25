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
     * succeeds, so a failed or cancelled write never touches another file.
     *
     * @param uri URI of the new entry
     * @param outputStream Stream to write the content to
     * @param overwrite OVERWRITE: the entry has a name of its own (a numbered
     *   or temporary one), and the commit gives it the requested name,
     *   replacing the file that holds that name then
     */
    class Created(
        val uri: Uri,
        val outputStream: OutputStream,
        val overwrite: Boolean = false,
    ) : SaveEntry()

    /**
     * The target file already exists and SKIP was requested: nothing is written,
     * and the save reports [uri] as its result.
     */
    class Existing(
        val uri: Uri,
    ) : SaveEntry()
}
