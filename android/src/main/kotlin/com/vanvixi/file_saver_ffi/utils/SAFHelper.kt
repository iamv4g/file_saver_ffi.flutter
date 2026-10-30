package com.vanvixi.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import com.vanvixi.file_saver_ffi.core.base.SaveEntry
import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import com.vanvixi.file_saver_ffi.models.FileType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.IOException

/**
 * Helper for Storage Access Framework (SAF) operations.
 *
 * SAF allows users to select directories via system picker,
 * and apps can then read/write files to those directories.
 */
object SAFHelper {
    /**
     * Creates a file in the user-selected directory.
     *
     * @param context Application context
     * @param treeUri Directory URI from ACTION_OPEN_DOCUMENT_TREE
     * @param fileType File type information (extension, mimeType)
     * @param baseFileName File name WITHOUT extension
     * @param conflictResolution How to handle existing files
     * @return [SaveEntry.Created] to write to, or [SaveEntry.Existing] for SKIP
     * @throws IOException if file creation fails
     * @throws FileExistsException if file exists and conflictResolution is FAIL
     */
    suspend fun createFileInDirectory(
        context: Context,
        treeUri: Uri,
        fileType: FileType,
        baseFileName: String,
        conflictResolution: ConflictResolution,
    ): SaveEntry =
        withContext(Dispatchers.IO) {
            val fileName = FileHelper.buildFileName(baseFileName, fileType.ext)
            val mimeType = fileType.mimeType
            val docDir =
                DocumentFile.fromTreeUri(context, treeUri)
                    ?: throw IOException("Cannot access directory: $treeUri")

            if (!docDir.isDirectory) {
                throw IOException("Not a directory: $treeUri")
            }

            if (!docDir.canWrite()) {
                throw IOException("Cannot write to directory: $treeUri")
            }

            // One listing serves the conflict check and the unique name.
            // DocumentFile.findFile would list the directory again for every
            // name it checks, with an IPC call per entry.
            val children = listChildren(context, docDir)
            val existingUri = children[fileName]

            if (existingUri != null) {
                when (conflictResolution) {
                    ConflictResolution.AUTO_RENAME -> {
                        // Generate unique name: photo.jpg → photo (1).jpg
                        val uniqueName = generateUniqueName(children.keys, baseFileName, fileType.ext)
                        return@withContext createNewFile(context, docDir, uniqueName, mimeType)
                    }

                    ConflictResolution.OVERWRITE -> {
                        // Write a new document next to the existing one (the
                        // provider gives it a unique name). commitFile deletes
                        // the existing document only after the write succeeds.
                        return@withContext createNewFile(context, docDir, fileName, mimeType, replaces = existingUri)
                    }

                    ConflictResolution.SKIP -> {
                        // Keep the existing document; nothing is written.
                        return@withContext SaveEntry.Existing(existingUri)
                    }

                    ConflictResolution.FAIL -> {
                        throw FileExistsException("File already exists: $fileName")
                    }
                }
            }

            // No conflict, create new file
            createNewFile(context, docDir, fileName, mimeType)
        }

    /**
     * Makes a fully written [entry] the saved file and returns its final URI.
     *
     * For OVERWRITE, deletes the replaced document and renames the new one
     * (created with a provider-chosen unique name) to [displayName]. If the old
     * document cannot be deleted or the new one cannot be renamed, the new file
     * keeps its unique name, so no data is lost.
     *
     * @param displayName The requested file name WITH extension
     */
    suspend fun commitFile(
        context: Context,
        entry: SaveEntry.Created,
        displayName: String,
    ): Uri =
        withContext(Dispatchers.IO) {
            val replaces = entry.replaces ?: return@withContext entry.uri
            val resolver = context.contentResolver

            val deleted =
                try {
                    DocumentsContract.deleteDocument(resolver, replaces)
                } catch (_: Exception) {
                    false
                }
            if (!deleted) return@withContext entry.uri

            try {
                DocumentsContract.renameDocument(resolver, entry.uri, displayName) ?: entry.uri
            } catch (_: Exception) {
                entry.uri
            }
        }

    /**
     * Creates a new file in the directory.
     */
    private fun createNewFile(
        context: Context,
        docDir: DocumentFile,
        fileName: String,
        mimeType: String,
        replaces: Uri? = null,
    ): SaveEntry.Created {
        val newFile =
            docDir.createFile(mimeType, fileName)
                ?: throw IOException("Failed to create file: $fileName")

        // Don't leave an empty document behind if the stream can't be opened.
        val outputStream =
            try {
                context.contentResolver.openOutputStream(newFile.uri)
                    ?: throw IOException("Failed to open output stream: $fileName")
            } catch (e: Exception) {
                newFile.delete()
                throw e as? IOException ?: IOException("Failed to open output stream: $fileName", e)
            }

        return SaveEntry.Created(newFile.uri, outputStream, replaces = replaces)
    }

    /**
     * Lists the display names of [docDir]'s children with their document URIs,
     * in one query.
     *
     * @throws IOException if the directory can't be listed
     */
    private fun listChildren(
        context: Context,
        docDir: DocumentFile,
    ): Map<String, Uri> {
        val childrenUri =
            DocumentsContract.buildChildDocumentsUriUsingTree(docDir.uri, DocumentsContract.getDocumentId(docDir.uri))
        val projection = arrayOf(DocumentsContract.Document.COLUMN_DOCUMENT_ID, DocumentsContract.Document.COLUMN_DISPLAY_NAME)
        val children = HashMap<String, Uri>()
        context.contentResolver.query(childrenUri, projection, null, null, null)?.use { cursor ->
            while (cursor.moveToNext()) {
                val documentId = cursor.getString(0) ?: continue
                val name = cursor.getString(1) ?: continue
                children.putIfAbsent(name, DocumentsContract.buildDocumentUriUsingTree(docDir.uri, documentId))
            }
        } ?: throw IOException("Cannot list directory: ${docDir.uri}")
        return children
    }

    /**
     * Returns the first of `base (1).ext`, `base (2).ext`, … not in [takenNames].
     * There always is one, because [takenNames] is finite.
     */
    private fun generateUniqueName(
        takenNames: Set<String>,
        baseFileName: String,
        extension: String,
    ): String =
        generateSequence(1) { it + 1 }
            .map { FileHelper.buildFileName("$baseFileName ($it)", extension) }
            .first { it !in takenNames }
}
