package com.iamv4g.file_saver_ffi.utils

import android.content.ContentUris
import android.content.ContentValues
import android.content.Context
import android.media.MediaScannerConnection
import android.net.Uri
import android.os.Build
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import com.iamv4g.file_saver_ffi.core.base.SaveEntry
import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.FileType
import com.iamv4g.file_saver_ffi.models.SaveLocation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
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
        // NonCancellable: a cancel while the entry is being created must not
        // drop it, or its row would never be deleted. The caller deletes it
        // once it sees the cancel, at its next suspension point.
        withContext(Dispatchers.IO + NonCancellable) {
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
            val resolver = context.contentResolver

            // Until the row is inserted, a concurrent save of the same name
            // would pick the same name.
            val (uri, target) =
                DirectoryLock.withLock(lockKey(dirPath)) {
                    val target =
                        when (
                            val resolution =
                                ScopedStoreConflictResolver.resolve(
                                    context,
                                    contentUri,
                                    dirPath,
                                    baseFileName,
                                    fileType.ext,
                                    conflictResolution,
                                )
                        ) {
                            is ScopedStoreConflictResolver.Resolution.Existing -> {
                                return@withContext SaveEntry.Existing(resolution.uri)
                            }

                            is ScopedStoreConflictResolver.Resolution.Create -> {
                                resolution
                            }
                        }

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
                    uri to target
                }

            // Don't leave an empty pending row behind if the stream can't be opened.
            val outputStream =
                try {
                    resolver.openOutputStream(uri)
                        ?: throw IOException("Failed to open OutputStream: ${target.displayName}")
                } catch (e: Exception) {
                    resolver.delete(uri, null, null)
                    throw e as? IOException ?: IOException("Failed to open OutputStream: ${target.displayName}", e)
                }

            SaveEntry.Created(uri, outputStream, overwrite = target.overwrite)
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
                    val outputStream =
                        try {
                            FileOutputStream(resolution.file)
                        } catch (e: IOException) {
                            // Release the name the resolver claimed.
                            resolution.file.delete()
                            throw e
                        }
                    SaveEntry.Created(Uri.fromFile(resolution.file), outputStream, overwrite = resolution.overwrite)
                }
            }
        }

    /**
     * Makes a fully written [entry] the saved file and returns its final URI.
     *
     * - Android 10+: clears IS_PENDING so the file becomes visible. For
     *   OVERWRITE it then deletes the row that holds [displayName] and gives
     *   the new row (inserted under a numbered name such as `photo (1).jpg`)
     *   that name.
     *   The new file keeps its numbered name if that row can't be deleted
     *   (for example a row the app does not own throws
     *   `RecoverableSecurityException`), or is still being written by another
     *   save.
     * - Android ≤ 9: for OVERWRITE, renames the temporary file to
     *   [displayName], replacing the file there, then asks the media scanner
     *   to index the file so it shows up in gallery and music apps (MediaStore
     *   is not updated by plain file writes there).
     *
     * Concurrent overwrites of one name end with the content of the one that
     * commits last.
     *
     * The stream of [entry] must already be closed.
     *
     * @param displayName The requested file name WITH extension
     * @param fileType The type of the file; its MIME type is passed to the
     *   media scanner on Android ≤ 9
     * @throws IOException if the entry cannot be finalized; the replaced file
     *   is still intact in that case
     */
    suspend fun commitEntry(
        context: Context,
        entry: SaveEntry.Created,
        displayName: String,
        fileType: FileType,
        saveLocation: SaveLocation,
        subDir: String?,
    ): Uri =
        withContext(Dispatchers.IO) {
            if (entry.uri.scheme == "file") {
                val uri = commitLegacyEntry(entry, displayName)
                // Fire-and-forget: the file is saved either way, the scan only
                // makes it visible to other apps.
                uri.path?.let { path ->
                    MediaScannerConnection.scanFile(context, arrayOf(path), arrayOf(fileType.mimeType), null)
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

            if (!entry.overwrite) return@withContext entry.uri

            val (contentUri, dirPath) = FileHelper.scopedStoreTargetFor(saveLocation, subDir, fileType)
            // So that no other save inserts or renames a row to displayName in
            // between.
            DirectoryLock.withLock(lockKey(dirPath)) {
                val holder =
                    try {
                        ScopedStoreConflictResolver.findRow(context, contentUri, dirPath, displayName)
                    } catch (_: Exception) {
                        return@withLock entry.uri
                    }
                if (holder != null && ContentUris.parseId(holder.uri) != ContentUris.parseId(entry.uri)) {
                    // Another save is writing it: its content isn't ours to drop.
                    if (holder.isPending) return@withLock entry.uri
                    val deleted =
                        try {
                            resolver.delete(holder.uri, null, null) > 0
                        } catch (_: SecurityException) {
                            false
                        }
                    if (!deleted) return@withLock entry.uri
                }
                try {
                    val rename = ContentValues().apply { put(MediaStore.MediaColumns.DISPLAY_NAME, displayName) }
                    resolver.update(entry.uri, rename, null, null)
                } catch (_: Exception) {
                    // The content is saved; only the name stays numbered.
                }
                entry.uri
            }
        }

    private fun commitLegacyEntry(
        entry: SaveEntry.Created,
        displayName: String,
    ): Uri {
        if (!entry.overwrite) return entry.uri
        val temp = File(requireNotNull(entry.uri.path))
        val target = File(temp.parentFile, displayName)
        // rename(2) replaces the target in one step.
        if (!temp.renameTo(target)) {
            throw IOException("Failed to replace ${target.name}")
        }
        return Uri.fromFile(target)
    }

    /** The [DirectoryLock] key of a MediaStore directory. */
    private fun lockKey(dirPath: String) = "media:${ScopedStoreConflictResolver.normalizeRelativePath(dirPath)}"
}
