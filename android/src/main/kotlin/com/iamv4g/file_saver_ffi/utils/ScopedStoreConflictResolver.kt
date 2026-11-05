package com.iamv4g.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object ScopedStoreConflictResolver {
    /** Outcome of resolving a MediaStore name conflict. */
    sealed class Resolution {
        /**
         * Insert a new row named [displayName]. [replaces] is the existing row to
         * delete once the new content is written (OVERWRITE only).
         */
        data class Create(
            val displayName: String,
            val replaces: Uri? = null,
        ) : Resolution()

        /** Keep the existing row and write nothing (SKIP). */
        data class Existing(
            val uri: Uri,
        ) : Resolution()
    }

    /**
     * Resolve file name conflict for MediaStore (Android 10+)
     *
     * Nothing is deleted here: OVERWRITE returns the existing row as
     * [Resolution.Create.replaces], and the caller deletes it after a
     * successful write.
     *
     * @param context Application context
     * @param contentUri MediaStore collection (Images / Video / Audio / Files)
     * @param dirPath Relative path (e.g. "Pictures/MyAlbum")
     * @param baseFileName File name WITHOUT extension
     * @param extension File extension WITHOUT dot
     * @param conflictResolution Strategy
     *
     * @throws FileExistsException if the file exists and [conflictResolution] is FAIL
     */
    suspend fun resolve(
        context: Context,
        contentUri: Uri,
        dirPath: String,
        baseFileName: String,
        extension: String,
        conflictResolution: ConflictResolution,
    ): Resolution =
        withContext(Dispatchers.IO) {
            val originalName = FileHelper.buildFileName(baseFileName, extension)
            val existingUri =
                findExistingFileUri(context, contentUri, dirPath, originalName)
                    ?: return@withContext Resolution.Create(originalName)

            // The plugin picks the numbered name: MediaProvider numbers a
            // taken name itself, but gives up after `name (31)`, and only
            // once the whole file is written.
            fun numberedName() =
                FileHelper.numberedName(
                    baseFileName,
                    extension,
                    takenNames(context, contentUri, dirPath)::contains,
                )

            when (conflictResolution) {
                // photo.jpg → photo (1).jpg → photo (2).jpg
                ConflictResolution.AUTO_RENAME -> {
                    Resolution.Create(numberedName())
                }

                // The new row gets a numbered name while the old one exists;
                // the commit deletes the old row and renames the new one back.
                ConflictResolution.OVERWRITE -> {
                    Resolution.Create(numberedName(), replaces = existingUri)
                }

                ConflictResolution.SKIP -> {
                    Resolution.Existing(existingUri)
                }

                ConflictResolution.FAIL -> {
                    throw FileExistsException(originalName)
                }
            }
        }

    /**
     * Find existing file URI in MediaStore
     *
     * @return URI if file exists, null otherwise
     */
    fun findExistingFileUri(
        context: Context,
        contentUri: Uri,
        dirPath: String,
        displayName: String,
    ): Uri? {
        val normalizedPath = normalizeRelativePath(dirPath)

        val projection = arrayOf(MediaStore.MediaColumns._ID)
        val selection =
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND " +
                "${MediaStore.MediaColumns.RELATIVE_PATH}=?"
        val selectionArgs = arrayOf(displayName, normalizedPath)

        val cursor =
            context.contentResolver.query(
                contentUri,
                projection,
                selection,
                selectionArgs,
                null,
            ) ?: return null

        cursor.use {
            if (it.moveToFirst()) {
                val id = it.getLong(it.getColumnIndexOrThrow(MediaStore.MediaColumns._ID))
                return android.content.ContentUris.withAppendedId(contentUri, id)
            }
        }

        return null
    }

    /** The display names of the rows in [dirPath] of [contentUri], in one query. */
    private fun takenNames(
        context: Context,
        contentUri: Uri,
        dirPath: String,
    ): Set<String> {
        val names = HashSet<String>()
        context.contentResolver
            .query(
                contentUri,
                arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
                "${MediaStore.MediaColumns.RELATIVE_PATH}=?",
                arrayOf(normalizeRelativePath(dirPath)),
                null,
            )?.use { cursor ->
                while (cursor.moveToNext()) cursor.getString(0)?.let(names::add)
            }
        return names
    }

    private fun normalizeRelativePath(dirPath: String): String = if (dirPath.endsWith("/")) dirPath else "$dirPath/"
}
