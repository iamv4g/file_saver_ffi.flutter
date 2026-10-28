package com.vanvixi.file_saver_ffi.utils

import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import com.vanvixi.file_saver_ffi.core.base.SaveEntry
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import com.vanvixi.file_saver_ffi.models.SaveLocation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileOutputStream
import java.io.IOException

object StoreHelper {
    /**
     * Creates MediaStore entry
     *
     * @param context Application context
     * @param fileType File type (e.g., ImageType, VideoType, AudioType, CustomFileType)
     * @param baseFileName Base file name WITHOUT extension (e.g., "photo")
     * @param subDir Subdirectory within Pictures (e.g., "MyAlbum"), null for Pictures root
     * @return [SaveEntry.Created] to write to, or [SaveEntry.Existing] for SKIP
     * @throws IOException if MediaStore entry creation fails
     * @throws FileExistsException if the file exists and [conflictResolution] is FAIL
     * @throws IllegalArgumentException if MediaProvider rejects [fileType] in
     *   [saveLocation] on Android 10+, or [subDir] contains `..`
     *
     * Example:
     * ```kotlin
     * val entry = StoreHelper.createEntry(
     *     context = context,
     *     fileType = fileType,
     *     baseFileName = "photo",
     *     subDir = "MyAlbum"
     * ) as SaveEntry.Created
     * entry.outputStream.use { it.write(imageData) }
     * val uri = StoreHelper.commitEntry(context, entry, "photo.jpg")
     * ```
     */
    suspend fun createEntry(
        context: Context,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String? = null,
        conflictResolution: ConflictResolution,
    ): SaveEntry =
        withContext(Dispatchers.IO) {
            val isVersionQPlus = Build.VERSION.SDK_INT >= Build.VERSION_CODES.Q

            if (isVersionQPlus) {
                return@withContext createEntryForScopedStorage(
                    context,
                    fileType,
                    baseFileName,
                    saveLocation,
                    subDir,
                    conflictResolution,
                )
            } else {
                return@withContext createEntryForLegacyStorage(
                    fileType,
                    baseFileName,
                    saveLocation,
                    subDir,
                    conflictResolution,
                )
            }
        }

    @RequiresApi(Build.VERSION_CODES.Q)
    private suspend fun createEntryForScopedStorage(
        context: Context,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String? = null,
        conflictResolution: ConflictResolution,
    ): SaveEntry =
        withContext(Dispatchers.IO) {
            val (contentUri, dirPath) = FileHelper.scopedStoreTargetFor(saveLocation, subDir, fileType)

            val resolution =
                ScopedStoreConflictResolver.resolve(
                    context,
                    contentUri,
                    dirPath,
                    baseFileName,
                    fileType.ext,
                    conflictResolution,
                )

            val target =
                when (resolution) {
                    is ScopedStoreConflictResolver.Resolution.Existing -> {
                        return@withContext SaveEntry.Existing(resolution.uri)
                    }

                    is ScopedStoreConflictResolver.Resolution.Create -> {
                        resolution
                    }
                }

            val resolver = context.contentResolver

            val contentValues =
                ContentValues().apply {
                    put(MediaStore.MediaColumns.DISPLAY_NAME, target.displayName)
                    put(MediaStore.MediaColumns.MIME_TYPE, fileType.mimeType)
                    put(MediaStore.MediaColumns.RELATIVE_PATH, dirPath)
                    put(MediaStore.MediaColumns.IS_PENDING, 1)
                }

            val uri =
                try {
                    resolver.insert(contentUri, contentValues)
                } catch (e: IllegalArgumentException) {
                    // MediaProvider rejects a top-level directory the collection
                    // doesn't allow, e.g. an image in Movies/.
                    throw IllegalArgumentException(
                        "Android rejected saving ${fileType.mimeType} to ${dirPath.substringBefore('/')}/: ${e.message}",
                        e,
                    )
                } ?: throw IOException("Failed to create MediaStore entry: ${target.displayName}")

            // Don't leave an empty pending row behind if the stream can't be opened.
            val outputStream =
                try {
                    resolver.openOutputStream(uri)
                        ?: throw IOException("Failed to open OutputStream: ${target.displayName}")
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e as? IOException ?: IOException("Failed to open OutputStream: ${target.displayName}", e)
                }

            SaveEntry.Created(uri, outputStream, replaces = target.replaces)
        }

    private suspend fun createEntryForLegacyStorage(
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String? = null,
        conflictResolution: ConflictResolution,
    ): SaveEntry =
        withContext(Dispatchers.IO) {
            val directory = FileHelper.legacyStoreDirectoryFor(saveLocation, subDir)
            FileHelper.ensureDirectoryExists(directory).getOrElse { error ->
                throw IOException("Failed to create directory: ${error.message}")
            }

            when (
                val resolution =
                    LegacyStoreConflictResolver.resolve(
                        directory,
                        baseFileName,
                        fileType.ext,
                        conflictResolution,
                    )
            ) {
                is LegacyStoreConflictResolver.Resolution.Existing -> {
                    SaveEntry.Existing(Uri.fromFile(resolution.file))
                }

                is LegacyStoreConflictResolver.Resolution.Create -> {
                    SaveEntry.Created(
                        uri = Uri.fromFile(resolution.file),
                        outputStream = FileOutputStream(resolution.file),
                        replaces = resolution.replaces?.let(Uri::fromFile),
                    )
                }
            }
        }

    /**
     * Makes a fully written [entry] the saved file and returns its final URI.
     *
     * - Android 10+: clears IS_PENDING so the file becomes visible. For
     *   OVERWRITE it then deletes the replaced row and renames the new row
     *   (auto-renamed to e.g. `photo (1).jpg` on insert) back to [displayName].
     *   If the old row cannot be deleted (for example a row the app does not
     *   own throws `RecoverableSecurityException`), the new file keeps its
     *   auto-renamed name.
     * - Android ≤ 9: for OVERWRITE, renames the temporary file over the original,
     *   then asks the media scanner to index the file so it shows up in gallery
     *   and music apps (MediaStore is not updated by plain file writes there).
     *
     * The stream of [entry] must already be closed.
     *
     * @param displayName The requested file name WITH extension
     * @param mimeType MIME type passed to the media scanner on Android ≤ 9
     * @throws IOException if the entry cannot be finalized; the replaced file
     *   is still intact in that case
     */
    suspend fun commitEntry(
        context: Context,
        entry: SaveEntry.Created,
        displayName: String,
        mimeType: String,
    ): Uri =
        withContext(Dispatchers.IO) {
            if (entry.uri.scheme == "file") {
                val uri = commitLegacyEntry(entry)
                // Fire-and-forget: the file is saved either way, the scan only
                // makes it visible to other apps.
                uri.path?.let { path ->
                    MediaScannerConnection.scanFile(context, arrayOf(path), arrayOf(mimeType), null)
                }
                return@withContext uri
            }

            val resolver = context.contentResolver
            val pending = ContentValues().apply { put(MediaStore.MediaColumns.IS_PENDING, 0) }
            // A row that stays pending is invisible to other apps and purged by
            // MediaStore after about a week, so this is a failed save.
            if (resolver.update(entry.uri, pending, null, null) != 1) {
                throw IOException("Failed to publish ${entry.uri}: MediaStore did not clear IS_PENDING")
            }

            val replaces = entry.replaces ?: return@withContext entry.uri

            val deleted =
                try {
                    resolver.delete(replaces, null, null) > 0
                } catch (_: SecurityException) {
                    false
                }
            if (deleted) {
                try {
                    val rename = ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, displayName) }
                    resolver.update(entry.uri, rename, null, null)
                } catch (_: Exception) {
                    // The content is saved; only the name stays auto-renamed.
                }
            }
            entry.uri
        }

    private fun commitLegacyEntry(entry: SaveEntry.Created): Uri {
        val replaces = entry.replaces ?: return entry.uri
        val temp = File(requireNotNull(entry.uri.path))
        val target = File(requireNotNull(replaces.path))
        if (!temp.renameTo(target)) {
            throw IOException("Failed to replace ${target.name}")
        }
        return replaces
    }

    /**
     * Converts content URI to file path
     *
     * Note: On Android 10+, file path may not be accessible directly
     * This is a best-effort attempt
     *
     * @param context Application context
     * @param uri Content URI
     * @return File path if available, empty string otherwise
     */
    suspend fun uriToFilePath(
        context: Context,
        uri: Uri,
    ): String =
        withContext(Dispatchers.IO) {
            try {
                // Try to get DATA column (file path)
                context.contentResolver
                    .query(
                        uri,
                        arrayOf(MediaStore.Images.Media.DATA),
                        null,
                        null,
                        null,
                    )?.use { cursor ->
                        if (cursor.moveToFirst()) {
                            val columnIndex = cursor.getColumnIndex(MediaStore.Images.Media.DATA)
                            if (columnIndex >= 0) {
                                return@withContext cursor.getString(columnIndex) ?: ""
                            }
                        }
                    }
            } catch (_: Exception) {
                // Ignore errors, fall back to empty string
            }

            // Fallback: Return empty string
            // On Android 10+, direct file paths are often not available
            ""
        }
}
