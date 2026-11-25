package com.iamv4g.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.provider.DocumentsContract
import androidx.documentfile.provider.DocumentFile
import com.iamv4g.file_saver_ffi.core.base.SaveEntry
import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.FileType
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.NonCancellable
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
        // NonCancellable, as in StoreHelper.createEntry: the caller deletes a
        // created document once it sees the cancel.
        withContext(Dispatchers.IO + NonCancellable) {
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

            val directory = treeUri.toString()
            // Until the document is created, a concurrent save of the same
            // name would pick the same name.
            val (uri, overwrite) =
                DirectoryLock.withLock(directory) {
                    // One listing serves the conflict check and the unique name.
                    // DocumentFile.findFile would list the directory again for every
                    // name it checks, with an IPC call per entry.
                    val children = listChildren(context, docDir)
                    val existingUri = children[fileName]

                    if (conflictResolution == ConflictResolution.OVERWRITE) {
                        // A document of its own, under a numbered name, which
                        // commitFile renames once it is written, replacing the
                        // document that holds the name then. The name isn't
                        // left to the provider: the system's gives up after
                        // `name (32)`.
                        val tempName = FileHelper.numberedName(baseFileName, fileType.ext, children::containsKey)
                        val temp = createDocument(docDir, tempName, mimeType)
                        // Without renaming it would keep the numbered name, so
                        // with no file to replace, write under the name itself.
                        if (existingUri == null && !supportsRename(context, temp)) {
                            deleteDocument(context, temp)
                            return@withLock createDocument(docDir, fileName, mimeType) to false
                        }
                        return@withLock temp to true
                    }

                    if (existingUri == null) return@withLock createDocument(docDir, fileName, mimeType) to false

                    when (conflictResolution) {
                        // Generate unique name: photo.jpg → photo (1).jpg
                        ConflictResolution.AUTO_RENAME -> {
                            val uniqueName = FileHelper.numberedName(baseFileName, fileType.ext, children::containsKey)
                            createDocument(docDir, uniqueName, mimeType) to false
                        }

                        // Keep the existing document; nothing is written.
                        ConflictResolution.SKIP -> {
                            return@withContext SaveEntry.Existing(existingUri)
                        }

                        ConflictResolution.FAIL -> {
                            throw FileExistsException(fileName)
                        }

                        ConflictResolution.OVERWRITE -> {
                            error("Handled above")
                        }
                    }
                }

            // Don't leave an empty document behind if the stream can't be opened.
            val outputStream =
                try {
                    context.contentResolver.openOutputStream(uri)
                        ?: throw IOException("Failed to open output stream: $uri")
                } catch (e: Exception) {
                    deleteDocument(context, uri)
                    throw e as? IOException ?: IOException("Failed to open output stream: $uri", e)
                }

            SaveEntry.Created(uri, outputStream, overwrite = overwrite)
        }

    /**
     * Makes a fully written [entry] the saved file and returns its final URI.
     *
     * For OVERWRITE, deletes the document that holds [displayName] in
     * [treeUri] and renames the new one (created with a numbered name) to
     * [displayName]. If the provider can't rename the new document, or the
     * old one cannot be deleted, both are kept and the new file keeps its
     * unique name, so no data is lost.
     * Concurrent overwrites of one name end with the content of the one that
     * commits last.
     *
     * @param displayName The requested file name WITH extension
     */
    suspend fun commitFile(
        context: Context,
        entry: SaveEntry.Created,
        treeUri: Uri,
        displayName: String,
    ): Uri =
        withContext(Dispatchers.IO) {
            if (!entry.overwrite) return@withContext entry.uri
            val resolver = context.contentResolver
            // Keep the replaced document unless the new one can take its name.
            if (!supportsRename(context, entry.uri)) return@withContext entry.uri

            // So that no other save creates or renames a document to
            // displayName in between.
            DirectoryLock.withLock(treeUri.toString()) {
                val holder =
                    try {
                        val docDir = DocumentFile.fromTreeUri(context, treeUri) ?: return@withLock entry.uri
                        listChildren(context, docDir)[displayName]
                    } catch (_: Exception) {
                        return@withLock entry.uri
                    }
                if (holder != null && DocumentsContract.getDocumentId(holder) != DocumentsContract.getDocumentId(entry.uri)) {
                    val deleted =
                        try {
                            DocumentsContract.deleteDocument(resolver, holder)
                        } catch (_: Exception) {
                            false
                        }
                    if (!deleted) return@withLock entry.uri
                }

                try {
                    DocumentsContract.renameDocument(resolver, entry.uri, displayName) ?: entry.uri
                } catch (_: Exception) {
                    entry.uri
                }
            }
        }

    /** Creates an empty document named [name] in [docDir] and returns its URI. */
    private fun createDocument(
        docDir: DocumentFile,
        name: String,
        mimeType: String,
    ): Uri = docDir.createFile(mimeType, name)?.uri ?: throw IOException("Failed to create file: $name")

    private fun deleteDocument(
        context: Context,
        uri: Uri,
    ) {
        try {
            DocumentsContract.deleteDocument(context.contentResolver, uri)
        } catch (_: Exception) {
        }
    }

    /** Whether the provider of the document [uri] can rename it. */
    private fun supportsRename(
        context: Context,
        uri: Uri,
    ): Boolean =
        try {
            context.contentResolver
                .query(uri, arrayOf(DocumentsContract.Document.COLUMN_FLAGS), null, null, null)
                ?.use { it.moveToFirst() && it.getInt(0) and DocumentsContract.Document.FLAG_SUPPORTS_RENAME != 0 }
                ?: false
        } catch (_: Exception) {
            false
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
}
