package com.iamv4g.file_saver_ffi.testing

import android.Manifest
import android.content.ContentProvider
import android.content.ContentValues
import android.content.pm.ProviderInfo
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Bundle
import android.os.CancellationSignal
import android.os.ParcelFileDescriptor
import android.provider.DocumentsContract
import android.provider.DocumentsContract.Document
import android.provider.DocumentsContract.Root
import android.provider.DocumentsProvider
import org.robolectric.Robolectric
import org.robolectric.shadows.ShadowContentResolver
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files
import java.util.concurrent.atomic.AtomicInteger

/**
 * An in-memory Storage Access Framework provider with one directory tree,
 * standing in for the provider behind a directory the user picked.
 *
 * Like `ExternalStorageProvider`, it gives a new document a unique name
 * (`name (1).ext`) when the requested one is taken. It counts directory
 * listings, which are IPC calls on a device.
 */
class FakeDocumentsProvider : DocumentsProvider() {
    class Doc(
        val id: String,
        var name: String,
        val mimeType: String,
        val parentId: String?,
    ) {
        var file: File? = null
    }

    val docs = linkedMapOf(ROOT_ID to Doc(ROOT_ID, "Picked", Document.MIME_TYPE_DIR, null))

    /** Number of `queryChildDocuments` calls (directory listings). */
    val childQueries = AtomicInteger()

    private var nextId = 1
    private val storageDir: File by lazy { Files.createTempDirectory("fake-saf").toFile() }

    /** The tree URI a directory picker would return for the root directory. */
    val treeUri: Uri get() = DocumentsContract.buildTreeDocumentUri(AUTHORITY, ROOT_ID)

    /** Adds an empty document named [name] to the root directory, as if it already existed. */
    @Synchronized
    fun addExisting(
        name: String,
        mimeType: String = "text/plain",
    ): Doc = Doc("doc${nextId++}", name, mimeType, ROOT_ID).also { docs[it.id] = it }

    /** The document named [name] in the root directory, or null. */
    @Synchronized
    fun docNamed(name: String): Doc? = docs.values.firstOrNull { it.parentId == ROOT_ID && it.name == name }

    /** The names in the root directory. */
    @Synchronized
    fun names(): List<String> = docs.values.filter { it.parentId == ROOT_ID }.map { it.name }

    fun contentOf(name: String): ByteArray? = docNamed(name)?.file?.readBytes()

    override fun onCreate() = true

    override fun queryRoots(projection: Array<out String>?): Cursor =
        MatrixCursor(projection ?: arrayOf(Root.COLUMN_ROOT_ID, Root.COLUMN_DOCUMENT_ID)).apply {
            newRow().add(Root.COLUMN_ROOT_ID, "root").add(Root.COLUMN_DOCUMENT_ID, ROOT_ID)
        }

    @Synchronized
    override fun queryDocument(
        documentId: String,
        projection: Array<out String>?,
    ): Cursor = cursor(projection).apply { addDoc(docs[documentId] ?: throw FileNotFoundException(documentId)) }

    @Synchronized
    override fun queryChildDocuments(
        parentDocumentId: String,
        projection: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        childQueries.incrementAndGet()
        return cursor(projection).apply { docs.values.filter { it.parentId == parentDocumentId }.forEach { addDoc(it) } }
    }

    override fun isChildDocument(
        parentDocumentId: String,
        documentId: String,
    ): Boolean = generateSequence(docs[documentId]) { docs[it.parentId] }.any { it.id == parentDocumentId }

    @Synchronized
    override fun createDocument(
        parentDocumentId: String,
        mimeType: String,
        displayName: String,
    ): String {
        val taken = docs.values.filter { it.parentId == parentDocumentId }.map { it.name }.toSet()
        val dot = displayName.lastIndexOf('.')
        val (base, ext) = if (dot > 0) displayName.substring(0, dot) to displayName.substring(dot) else displayName to ""
        val name = generateSequence(0) { it + 1 }.map { if (it == 0) displayName else "$base ($it)$ext" }.first { it !in taken }
        val doc = Doc("doc${nextId++}", name, mimeType, parentDocumentId)
        docs[doc.id] = doc
        return doc.id
    }

    @Synchronized
    override fun deleteDocument(documentId: String) {
        val doc = docs.remove(documentId) ?: throw FileNotFoundException(documentId)
        doc.file?.delete()
    }

    @Synchronized
    override fun renameDocument(
        documentId: String,
        displayName: String,
    ): String? {
        val doc = docs[documentId] ?: throw FileNotFoundException(documentId)
        if (docs.values.any { it.parentId == doc.parentId && it.name == displayName && it !== doc }) {
            throw IllegalStateException("$displayName exists")
        }
        doc.name = displayName
        return null
    }

    override fun openDocument(
        documentId: String,
        mode: String,
        signal: CancellationSignal?,
    ): ParcelFileDescriptor {
        val file =
            synchronized(this) {
                val doc = docs[documentId] ?: throw FileNotFoundException(documentId)
                doc.file ?: File(storageDir, documentId).apply { createNewFile() }.also { doc.file = it }
            }
        return ParcelFileDescriptor.open(file, ParcelFileDescriptor.parseMode(mode))
    }

    private fun cursor(projection: Array<out String>?) = MatrixCursor(projection ?: DEFAULT_PROJECTION)

    private fun MatrixCursor.addDoc(doc: Doc) {
        val flags =
            if (doc.mimeType == Document.MIME_TYPE_DIR) {
                Document.FLAG_DIR_SUPPORTS_CREATE
            } else {
                Document.FLAG_SUPPORTS_WRITE or Document.FLAG_SUPPORTS_DELETE or Document.FLAG_SUPPORTS_RENAME
            }
        val row = newRow()
        row.add(Document.COLUMN_DOCUMENT_ID, doc.id)
        row.add(Document.COLUMN_DISPLAY_NAME, doc.name)
        row.add(Document.COLUMN_MIME_TYPE, doc.mimeType)
        row.add(Document.COLUMN_FLAGS, flags)
        row.add(Document.COLUMN_SIZE, doc.file?.length() ?: 0L)
        row.add(Document.COLUMN_LAST_MODIFIED, 0L)
    }

    companion object {
        const val AUTHORITY = "com.iamv4g.file_saver_ffi.test.documents"
        const val ROOT_ID = "root"

        private val DEFAULT_PROJECTION =
            arrayOf(
                Document.COLUMN_DOCUMENT_ID,
                Document.COLUMN_DISPLAY_NAME,
                Document.COLUMN_MIME_TYPE,
                Document.COLUMN_FLAGS,
                Document.COLUMN_SIZE,
                Document.COLUMN_LAST_MODIFIED,
            )

        /** Registers a new provider under [AUTHORITY] with the attributes a DocumentsProvider requires. */
        fun install(): FakeDocumentsProvider {
            val provider =
                Robolectric
                    .buildContentProvider(FakeDocumentsProvider::class.java)
                    .create(
                        ProviderInfo().apply {
                            authority = AUTHORITY
                            exported = true
                            grantUriPermissions = true
                            readPermission = Manifest.permission.MANAGE_DOCUMENTS
                            writePermission = Manifest.permission.MANAGE_DOCUMENTS
                        },
                    ).get()
            val bridge = QueryBridge(provider).apply { attachInfo(provider.context, ProviderInfo().apply { authority = AUTHORITY }) }
            ShadowContentResolver.registerProviderInternal(AUTHORITY, bridge)
            return provider
        }
    }

    /**
     * Robolectric's ContentResolver calls the pre-Android-O `query`, which
     * DocumentsProvider rejects (it is final). This passes queries on as the
     * Bundle form Android uses, and everything else unchanged.
     */
    private class QueryBridge(
        private val target: DocumentsProvider,
    ) : ContentProvider() {
        override fun onCreate() = true

        override fun query(
            uri: Uri,
            projection: Array<out String>?,
            selection: String?,
            selectionArgs: Array<out String>?,
            sortOrder: String?,
        ): Cursor? = target.query(uri, projection, Bundle(), null)

        override fun call(
            authority: String,
            method: String,
            arg: String?,
            extras: Bundle?,
        ): Bundle? = target.call(authority, method, arg, extras)

        override fun call(
            method: String,
            arg: String?,
            extras: Bundle?,
        ): Bundle? = target.call(method, arg, extras)

        override fun openFile(
            uri: Uri,
            mode: String,
        ): ParcelFileDescriptor? = target.openFile(uri, mode)

        override fun getType(uri: Uri): String? = target.getType(uri)

        override fun insert(
            uri: Uri,
            values: ContentValues?,
        ): Uri? = throw UnsupportedOperationException()

        override fun update(
            uri: Uri,
            values: ContentValues?,
            selection: String?,
            selectionArgs: Array<out String>?,
        ): Int = throw UnsupportedOperationException()

        override fun delete(
            uri: Uri,
            selection: String?,
            selectionArgs: Array<out String>?,
        ): Int = throw UnsupportedOperationException()
    }
}
