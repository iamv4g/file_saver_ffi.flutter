package com.vanvixi.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.provider.MediaStore
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
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

            when (conflictResolution) {
                // MediaStore automatically handles conflicts by appending numbers
                // photo.jpg → photo (1).jpg → photo (2).jpg
                ConflictResolution.AUTO_RENAME -> {
                    Resolution.Create(originalName)
                }

                // The new row is auto-renamed while the old one exists; the
                // commit deletes the old row and renames the new one back.
                ConflictResolution.OVERWRITE -> {
                    Resolution.Create(originalName, replaces = existingUri)
                }

                ConflictResolution.SKIP -> {
                    Resolution.Existing(existingUri)
                }

                ConflictResolution.FAIL -> {
                    throw FileExistsException("File already exists: $originalName")
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

    private fun normalizeRelativePath(dirPath: String): String = if (dirPath.endsWith("/")) dirPath else "$dirPath/"
}
