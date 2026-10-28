package com.vanvixi.file_saver_ffi.core.base

import android.content.Context
import android.net.Uri
import androidx.documentfile.provider.DocumentFile
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import com.vanvixi.file_saver_ffi.models.SaveLocation
import com.vanvixi.file_saver_ffi.models.SaveProgressEvent
import com.vanvixi.file_saver_ffi.utils.Constants
import com.vanvixi.file_saver_ffi.utils.FileHelper
import com.vanvixi.file_saver_ffi.utils.SAFHelper
import com.vanvixi.file_saver_ffi.utils.StoreHelper
import kotlinx.coroutines.NonCancellable
import kotlinx.coroutines.channels.ProducerScope
import kotlinx.coroutines.withContext
import java.io.File
import java.io.IOException

/**
 * Factory for creating save entries (MediaStore or SAF).
 *
 * This sealed class abstracts the differences between saving to MediaStore
 * (gallery, downloads, etc.) and saving to user-selected directories via SAF.
 *
 * Lifecycle: [createEntry] resolves the conflict, the caller writes to
 * [SaveEntry.Created.outputStream], then [finishSave] (or [commitEntry])
 * makes the new entry the saved file. On failure the caller calls
 * [deleteEntry], which only removes the new entry.
 */
sealed class SaveEntryFactory {
    /**
     * Creates an entry with standardized error handling.
     * Returns null and sends error event if creation fails.
     */
    abstract suspend fun createEntry(
        scope: ProducerScope<SaveProgressEvent>,
        context: Context,
        conflictResolution: ConflictResolution,
    ): SaveEntry?

    /**
     * Creates an entry for streaming write sessions.
     * Throws instead of emitting to a ProducerScope — caller handles errors.
     *
     * @throws IOException if I/O error occurs
     * @throws FileExistsException if file already exists and conflict resolution requires it
     */
    abstract suspend fun createEntryDirect(
        context: Context,
        conflictResolution: ConflictResolution,
    ): SaveEntry

    /**
     * Deletes a new entry on error/cancellation. Never touches the file it replaces.
     */
    abstract fun deleteEntry(
        context: Context,
        uri: Uri,
    )

    /**
     * Makes a fully written [entry] the saved file and returns its final URI.
     *
     * For OVERWRITE, the replaced file is removed only here, after the new
     * content exists. If it cannot be removed, the new file is kept under its
     * auto-renamed name instead of failing, so no data is lost.
     *
     * Implementations must only throw before they modify the replaced file.
     *
     * @throws IOException if the entry cannot be finalized
     */
    abstract suspend fun commitEntry(
        context: Context,
        entry: SaveEntry.Created,
    ): Uri

    /**
     * Completes save operation (progress 0.9 → 1.0 → Success).
     */
    suspend fun finishSave(
        scope: ProducerScope<SaveProgressEvent>,
        context: Context,
        entry: SaveEntry.Created,
    ) {
        scope.sendProgress(0.9)
        // NonCancellable: once the replaced file may be gone, a cancellation
        // must not make the caller delete the new one as well. commitEntry only
        // throws before it touches the replaced file, so deleting the new entry
        // on failure is safe.
        val uri =
            try {
                withContext(NonCancellable) { commitEntry(context, entry) }
            } catch (e: Exception) {
                deleteEntry(context, entry.uri)
                scope.sendError(Constants.ERROR_FILE_IO, "Failed to finalize file: ${e.message}")
                return
            }
        scope.sendProgress(1.0)
        scope.sendSuccess(uri.toString())
    }

    // ─────────────────────────────────────────────────────────────────────────
    // MediaStore Implementation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Factory for saving to MediaStore (gallery, downloads, music, etc.)
     *
     * @param fileType File type information (extension, mimeType)
     * @param baseFileName File name WITHOUT extension
     * @param saveLocation Target MediaStore location
     * @param subDir Optional subdirectory within target location
     */
    data class MediaStore(
        val fileType: FileType,
        val baseFileName: String,
        val saveLocation: SaveLocation,
        val subDir: String?,
    ) : SaveEntryFactory() {
        override suspend fun createEntry(
            scope: ProducerScope<SaveProgressEvent>,
            context: Context,
            conflictResolution: ConflictResolution,
        ): SaveEntry? =
            try {
                createEntryDirect(context, conflictResolution)
            } catch (e: IOException) {
                scope.sendError(Constants.ERROR_FILE_IO, "Failed to create MediaStore entry: ${e.message}")
                null
            } catch (e: FileExistsException) {
                scope.sendError(Constants.ERROR_FILE_EXISTS, e.message ?: "File already exists")
                null
            } catch (e: IllegalArgumentException) {
                // A target the input can't be saved to: a file type the location
                // rejects, a `..` in subDir, or a URI that isn't a directory tree.
                scope.sendError(Constants.ERROR_INVALID_INPUT, e.message ?: "Invalid save target")
                null
            }

        override suspend fun createEntryDirect(
            context: Context,
            conflictResolution: ConflictResolution,
        ): SaveEntry = StoreHelper.createEntry(context, fileType, baseFileName, saveLocation, subDir, conflictResolution)

        override fun deleteEntry(
            context: Context,
            uri: Uri,
        ) {
            try {
                // Legacy storage (API < 29) entries are plain files.
                if (uri.scheme == "file") {
                    uri.path?.let { File(it).delete() }
                } else {
                    context.contentResolver.delete(uri, null, null)
                }
            } catch (_: Exception) {
            }
        }

        override suspend fun commitEntry(
            context: Context,
            entry: SaveEntry.Created,
        ): Uri =
            StoreHelper.commitEntry(
                context,
                entry,
                FileHelper.buildFileName(baseFileName, fileType.ext),
                fileType.mimeType,
            )
    }

    // ─────────────────────────────────────────────────────────────────────────
    // SAF (User-Selected Directory) Implementation
    // ─────────────────────────────────────────────────────────────────────────

    /**
     * Factory for saving to user-selected directory via Storage Access Framework.
     *
     * @param treeUri Directory URI from ACTION_OPEN_DOCUMENT_TREE
     * @param fileType File type information (extension, mimeType)
     * @param baseFileName File name WITHOUT extension
     */
    data class SAF(
        val treeUri: Uri,
        val fileType: FileType,
        val baseFileName: String,
    ) : SaveEntryFactory() {
        override suspend fun createEntry(
            scope: ProducerScope<SaveProgressEvent>,
            context: Context,
            conflictResolution: ConflictResolution,
        ): SaveEntry? =
            try {
                createEntryDirect(context, conflictResolution)
            } catch (e: IOException) {
                scope.sendError(Constants.ERROR_FILE_IO, "Failed to create file: ${e.message}")
                null
            } catch (e: FileExistsException) {
                scope.sendError(Constants.ERROR_FILE_EXISTS, e.message ?: "File already exists")
                null
            } catch (e: IllegalArgumentException) {
                // A target the input can't be saved to: a file type the location
                // rejects, a `..` in subDir, or a URI that isn't a directory tree.
                scope.sendError(Constants.ERROR_INVALID_INPUT, e.message ?: "Invalid save target")
                null
            }

        override suspend fun createEntryDirect(
            context: Context,
            conflictResolution: ConflictResolution,
        ): SaveEntry = SAFHelper.createFileInDirectory(context, treeUri, fileType, baseFileName, conflictResolution)

        override fun deleteEntry(
            context: Context,
            uri: Uri,
        ) {
            try {
                DocumentFile.fromSingleUri(context, uri)?.delete()
            } catch (_: Exception) {
            }
        }

        override suspend fun commitEntry(
            context: Context,
            entry: SaveEntry.Created,
        ): Uri =
            SAFHelper.commitFile(
                context,
                entry,
                FileHelper.buildFileName(baseFileName, fileType.ext),
            )
    }
}
