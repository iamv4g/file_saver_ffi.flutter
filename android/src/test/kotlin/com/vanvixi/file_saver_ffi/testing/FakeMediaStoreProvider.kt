package com.vanvixi.file_saver_ffi.testing

import android.content.ContentProvider
import android.content.ContentUris
import android.content.ContentValues
import android.database.Cursor
import android.database.MatrixCursor
import android.net.Uri
import android.os.Build
import android.os.ParcelFileDescriptor
import android.provider.MediaStore.MediaColumns
import org.robolectric.Robolectric
import java.io.File
import java.io.FileNotFoundException
import java.nio.file.Files

/**
 * In-memory stand-in for the system MediaProvider (authority `media`), backed
 * by real files so streams can be written and read back.
 *
 * It reproduces the MediaProvider behaviour the plugin relies on:
 * - `insert` rejects a MIME type that doesn't belong to the collection
 *   (`video/mp4` into Images throws [IllegalArgumentException]).
 * - `insert` rejects a `RELATIVE_PATH` whose top-level directory the
 *   collection doesn't allow (an image in `Movies/`), like MediaProvider's
 *   "Primary directory … not allowed" check.
 * - `insert` auto-renames a duplicate `DISPLAY_NAME` in the same
 *   `RELATIVE_PATH` to `name (1).ext`.
 * - `insert` stores `RELATIVE_PATH` with a trailing slash (`Pictures/album/`),
 *   as MediaProvider does, so queries must match that form.
 * - `query` supports `col=?` selections joined with `AND`.
 *
 * Install with [install] inside a Robolectric test.
 */
class FakeMediaStoreProvider : ContentProvider() {
    data class Row(
        val id: Long,
        val collection: String,
        val values: ContentValues,
        val file: File,
    ) {
        val displayName get() = values.getAsString(MediaColumns.DISPLAY_NAME)
        val relativePath get() = values.getAsString(MediaColumns.RELATIVE_PATH)
        val isPending get() = values.getAsInteger(MediaColumns.IS_PENDING) == 1
    }

    val rows = linkedMapOf<Long, Row>()

    /** Overrides the number of rows `update` reports, e.g. 0 to simulate a failed IS_PENDING clear. */
    var updateResult: ((Row, ContentValues) -> Int)? = null
    private var nextId = 1L
    private val storageDir: File by lazy { Files.createTempDirectory("fake-media").toFile() }

    /** Runs before `openFile` opens a row's file, e.g. to block like a slow provider. */
    @Volatile
    var beforeOpenFile: () -> Unit = {}

    override fun onCreate() = true

    override fun getType(uri: Uri): String? = rowFor(uri)?.values?.getAsString(MediaColumns.MIME_TYPE)

    @Synchronized
    override fun insert(
        uri: Uri,
        values: ContentValues?,
    ): Uri {
        val collection = collectionOf(uri)
        val row = ContentValues(values ?: ContentValues())
        val mimeType = row.getAsString(MediaColumns.MIME_TYPE).orEmpty()

        val expectedPrefix =
            when (collection) {
                "images" -> "image/"
                "video" -> "video/"
                "audio" -> "audio/"
                else -> null
            }
        if (expectedPrefix != null && !mimeType.startsWith(expectedPrefix)) {
            throw IllegalArgumentException(
                "MIME type $mimeType cannot be inserted into $uri; expected MIME type under $expectedPrefix*",
            )
        }

        row.getAsString(MediaColumns.RELATIVE_PATH)?.let { path ->
            row.put(MediaColumns.RELATIVE_PATH, if (path.endsWith("/")) path else "$path/")
        }
        val primaryDir = row.getAsString(MediaColumns.RELATIVE_PATH).orEmpty().substringBefore('/')
        val allowedDirs = allowedDirectories(collection)
        if (allowedDirs != null && primaryDir !in allowedDirs) {
            throw IllegalArgumentException(
                "Primary directory $primaryDir not allowed for $uri; allowed directories are $allowedDirs",
            )
        }

        row.put(MediaColumns.DISPLAY_NAME, uniqueName(row.getAsString(MediaColumns.DISPLAY_NAME), row.getAsString(MediaColumns.RELATIVE_PATH)))

        val id = nextId++
        val file = File(storageDir, "$id").apply { createNewFile() }
        rows[id] = Row(id, collection, row, file)
        return ContentUris.withAppendedId(baseUri(uri), id)
    }

    @Synchronized
    override fun query(
        uri: Uri,
        projection: Array<out String>?,
        selection: String?,
        selectionArgs: Array<out String>?,
        sortOrder: String?,
    ): Cursor {
        val columns = projection ?: arrayOf(MediaColumns._ID, MediaColumns.DISPLAY_NAME, MediaColumns.RELATIVE_PATH, MediaColumns.MIME_TYPE, MediaColumns.IS_PENDING)
        val filters = parseSelection(selection, selectionArgs)
        val id = idOf(uri)
        val collection = collectionOf(uri)

        val cursor = MatrixCursor(columns)
        rows.values
            .filter { id == null || it.id == id }
            .filter { collection == "file" || it.collection == collection }
            .filter { row -> filters.all { (column, value) -> row.values.getAsString(column) == value } }
            .forEach { row ->
                cursor.addRow(columns.map { if (it == MediaColumns._ID) row.id else row.values.get(it) })
            }
        return cursor
    }

    @Synchronized
    override fun update(
        uri: Uri,
        values: ContentValues?,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        val row = rowFor(uri) ?: return 0
        val changes = values ?: ContentValues()
        updateResult?.let { override -> return override(row, changes) }
        row.values.putAll(changes)
        return 1
    }

    @Synchronized
    override fun delete(
        uri: Uri,
        selection: String?,
        selectionArgs: Array<out String>?,
    ): Int {
        val row = rowFor(uri) ?: return 0
        rows.remove(row.id)
        row.file.delete()
        return 1
    }

    override fun openFile(
        uri: Uri,
        mode: String,
    ): ParcelFileDescriptor {
        beforeOpenFile()
        val row = synchronized(this) { rowFor(uri) } ?: throw FileNotFoundException("No row for $uri")
        return ParcelFileDescriptor.open(row.file, ParcelFileDescriptor.parseMode(mode))
    }

    /** The row with [displayName], or null. */
    @Synchronized
    fun rowNamed(displayName: String): Row? = rows.values.firstOrNull { it.displayName == displayName }

    private fun rowFor(uri: Uri): Row? = idOf(uri)?.let { rows[it] }

    private fun uniqueName(
        name: String,
        relativePath: String?,
    ): String {
        fun taken(candidate: String) = rows.values.any { it.displayName == candidate && it.relativePath == relativePath }
        if (!taken(name)) return name
        val dot = name.lastIndexOf('.')
        val (base, ext) = if (dot > 0) name.substring(0, dot) to name.substring(dot) else name to ""
        return generateSequence(1) { it + 1 }.map { "$base ($it)$ext" }.first { !taken(it) }
    }

    companion object {
        /**
         * Top-level directories MediaProvider accepts per collection, as
         * measured on a Galaxy Note 9 (Android 10) and a Galaxy S22
         * (Android 16). Android 10 rejects a video in Pictures/ and Android 16
         * accepts it. Versions in between weren't measured; the fake accepts
         * it from Android 11.
         */
        private fun allowedDirectories(collection: String): List<String>? =
            when (collection) {
                "images" -> listOf("DCIM", "Pictures")
                "video" -> if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) listOf("DCIM", "Movies", "Pictures") else listOf("DCIM", "Movies")
                "audio" -> listOf("Alarms", "Audiobooks", "Music", "Notifications", "Podcasts", "Recordings", "Ringtones")
                "downloads" -> listOf("Download")
                else -> null
            }

        fun install(): FakeMediaStoreProvider = Robolectric.setupContentProvider(FakeMediaStoreProvider::class.java, "media")

        /** `images`, `video`, `audio`, `downloads` or `file`, from `content://media/<volume>/<collection>/…`. */
        private fun collectionOf(uri: Uri): String = uri.pathSegments.getOrNull(1) ?: error("Not a MediaStore URI: $uri")

        private fun idOf(uri: Uri): Long? = uri.lastPathSegment?.toLongOrNull()

        /** The collection URI without a trailing row id. */
        private fun baseUri(uri: Uri): Uri =
            if (idOf(uri) == null) uri else uri.buildUpon().path(uri.pathSegments.dropLast(1).joinToString("/", prefix = "/")).build()

        private fun parseSelection(
            selection: String?,
            args: Array<out String>?,
        ): List<Pair<String, String?>> {
            if (selection.isNullOrBlank()) return emptyList()
            val clauses = selection.split(Regex("\\s+AND\\s+", RegexOption.IGNORE_CASE))
            require(clauses.size == (args?.size ?: 0)) { "Unsupported selection: $selection" }
            return clauses.mapIndexed { i, clause ->
                val column = clause.substringBefore('=').trim()
                require(clause.substringAfter('=').trim() == "?" && column.isNotEmpty()) { "Unsupported selection: $selection" }
                column to args!![i]
            }
        }
    }
}
