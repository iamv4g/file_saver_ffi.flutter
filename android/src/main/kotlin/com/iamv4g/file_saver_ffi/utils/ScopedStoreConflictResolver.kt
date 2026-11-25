package com.iamv4g.file_saver_ffi.utils

import android.content.ContentResolver
import android.content.ContentUris
import android.content.Context
import android.database.Cursor
import android.net.Uri
import android.os.Build
import android.os.Bundle
import android.provider.MediaStore
import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

object ScopedStoreConflictResolver {
    /** Outcome of resolving a MediaStore name conflict. */
    sealed class Resolution {
        /**
         * Insert a new row named [displayName]. For OVERWRITE ([overwrite]) it
         * is a free numbered name, and the commit gives the row the requested
         * name once its content is written.
         */
        data class Create(
            val displayName: String,
            val overwrite: Boolean = false,
        ) : Resolution()

        /** Keep the existing row and write nothing (SKIP). */
        data class Existing(
            val uri: Uri,
        ) : Resolution()
    }

    /** A MediaStore row, and whether a save is still writing it. */
    data class Row(
        val uri: Uri,
        val isPending: Boolean,
    )

    /**
     * Resolve file name conflict for MediaStore (Android 10+)
     *
     * Hold [DirectoryLock] for [dirPath] from this call until the row is
     * inserted, so that a concurrent save of the same name sees that row.
     * Nothing is deleted here: OVERWRITE always inserts under a numbered name,
     * and the commit replaces the file that holds the requested name then.
     *
     * Rows that are still being written (`IS_PENDING`) count as taken.
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
            // The plugin picks the numbered name: MediaProvider numbers a
            // taken name itself, but gives up after `name (31)`, and only
            // once the whole file is written.
            fun numberedName() =
                FileHelper.numberedName(
                    baseFileName,
                    extension,
                    takenNames(context, contentUri, dirPath)::contains,
                )

            // Concurrent overwrites must not write to a row another one is
            // about to replace, so even without a conflict the new row gets a
            // name of its own.
            if (conflictResolution == ConflictResolution.OVERWRITE) {
                return@withContext Resolution.Create(numberedName(), overwrite = true)
            }

            val originalName = FileHelper.buildFileName(baseFileName, extension)
            val existing =
                findRow(context, contentUri, dirPath, originalName)
                    ?: return@withContext Resolution.Create(originalName)

            when (conflictResolution) {
                // photo.jpg → photo (1).jpg → photo (2).jpg
                ConflictResolution.AUTO_RENAME -> Resolution.Create(numberedName())
                ConflictResolution.SKIP -> Resolution.Existing(existing.uri)
                ConflictResolution.FAIL -> throw FileExistsException(originalName)
                ConflictResolution.OVERWRITE -> error("Handled above")
            }
        }

    /**
     * The row named [displayName] in [dirPath] of [contentUri], also if it is
     * still pending, or null if there is none.
     */
    fun findRow(
        context: Context,
        contentUri: Uri,
        dirPath: String,
        displayName: String,
    ): Row? =
        query(
            context,
            contentUri,
            arrayOf(MediaStore.MediaColumns._ID, MediaStore.MediaColumns.IS_PENDING),
            "${MediaStore.MediaColumns.DISPLAY_NAME}=? AND ${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(displayName, normalizeRelativePath(dirPath)),
        )?.use {
            if (!it.moveToFirst()) return null
            Row(ContentUris.withAppendedId(contentUri, it.getLong(0)), !it.isNull(1) && it.getInt(1) == 1)
        }

    /**
     * The display names of the rows in [dirPath] of [contentUri], pending ones
     * included, in one query.
     */
    private fun takenNames(
        context: Context,
        contentUri: Uri,
        dirPath: String,
    ): Set<String> {
        val names = HashSet<String>()
        query(
            context,
            contentUri,
            arrayOf(MediaStore.MediaColumns.DISPLAY_NAME),
            "${MediaStore.MediaColumns.RELATIVE_PATH}=?",
            arrayOf(normalizeRelativePath(dirPath)),
        )?.use { cursor ->
            while (cursor.moveToNext()) cursor.getString(0)?.let(names::add)
        }
        return names
    }

    /**
     * Queries [contentUri] including pending rows. Android 11 and later return
     * the app's own pending rows by default; Android 10 returns none unless
     * asked.
     */
    private fun query(
        context: Context,
        contentUri: Uri,
        projection: Array<String>,
        selection: String,
        selectionArgs: Array<String>,
    ): Cursor? =
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            val args =
                Bundle().apply {
                    putString(ContentResolver.QUERY_ARG_SQL_SELECTION, selection)
                    putStringArray(ContentResolver.QUERY_ARG_SQL_SELECTION_ARGS, selectionArgs)
                    putInt(MediaStore.QUERY_ARG_MATCH_PENDING, MediaStore.MATCH_INCLUDE)
                }
            context.contentResolver.query(contentUri, projection, args, null)
        } else {
            @Suppress("DEPRECATION")
            context.contentResolver.query(MediaStore.setIncludePending(contentUri), projection, selection, selectionArgs, null)
        }

    /** MediaProvider stores RELATIVE_PATH with a trailing slash. */
    fun normalizeRelativePath(dirPath: String): String = if (dirPath.endsWith("/")) dirPath else "$dirPath/"
}
