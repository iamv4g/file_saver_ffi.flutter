package com.iamv4g.file_saver_ffi.utils

import android.content.ActivityNotFoundException
import android.content.ClipData
import android.content.Context
import android.content.Intent
import android.content.pm.PackageManager
import android.net.Uri
import android.os.Build
import android.webkit.MimeTypeMap
import androidx.core.content.FileProvider
import androidx.core.net.toUri
import com.iamv4g.file_saver_ffi.exception.FileOpenException
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException

internal object FileOpener {
    private val androidConfigDocUrl =
        "https://pub.dev/packages/file_saver_ffi#:~:text=Android%20Configuration"

    /**
     * Checks whether the file at the given URI is accessible for reading.
     *
     * Supports:
     * - content:// (MediaStore, SAF): tries opening a read-only FileDescriptor via ContentResolver.
     * - file:// (filesystem path): checks file exists and is readable.
     *
     * Makes a blocking IPC call for content:// URIs, so it must not run on the main thread.
     *
     * @param context Application context
     * @param uri URI string (content:// or file://)
     * @return true if the file is readable, false otherwise
     */
    fun canOpenFile(
        context: Context,
        uri: String,
    ): Boolean =
        try {
            checkReadable(context, uri.toUri())
            true
        } catch (_: Exception) {
            false
        }

    /**
     * Opens a saved file with the appropriate system app.
     *
     * Uses Intent.ACTION_VIEW with FLAG_GRANT_READ_URI_PERMISSION, so no additional
     * permissions are required — the app already owns the content URI it created.
     *
     * Supports:
     * - content:// (MediaStore, SAF): opens directly.
     * - file:// (filesystem path): requires the host app to configure a FileProvider.
     *
     * Makes blocking IPC calls, so it must not run on the main thread.
     *
     * @param context Application context
     * @param uri Content URI or file URI string returned from save operations
     * @param mimeType Optional MIME type.
     *   - If null and uri is content://, queried from ContentResolver automatically.
     *   - If null and uri is file://, inferred from file extension when possible.
     * @throws FileOpenException with [Constants.ERROR_INVALID_INPUT] for an
     *   unsupported URI, [Constants.ERROR_FILE_NOT_FOUND] if the file doesn't
     *   exist, or [Constants.ERROR_OPEN_FAILED] if it can't be read or opened
     */
    fun openFile(
        context: Context,
        uri: String,
        mimeType: String?,
    ) {
        val parsedUri = uri.toUri()
        checkReadable(context, parsedUri)
        val intentUri = if (parsedUri.scheme == "file") resolveFileUri(context, parsedUri) else parsedUri

        val resolvedMime =
            mimeType
                ?: context.contentResolver.getType(intentUri)
                ?: run {
                    val ext = MimeTypeMap.getFileExtensionFromUrl(intentUri.toString())
                    if (ext.isNullOrEmpty()) {
                        "*/*"
                    } else {
                        MimeTypeMap.getSingleton().getMimeTypeFromExtension(ext.lowercase()) ?: "*/*"
                    }
                }

        val intent =
            Intent(Intent.ACTION_VIEW).apply {
                setDataAndType(intentUri, resolvedMime)
                addFlags(Intent.FLAG_ACTIVITY_NEW_TASK or Intent.FLAG_GRANT_READ_URI_PERMISSION)
                clipData = ClipData.newUri(context.contentResolver, "file", intentUri)
            }

        try {
            context.startActivity(intent)
        } catch (e: ActivityNotFoundException) {
            throw FileOpenException(
                Constants.ERROR_OPEN_FAILED,
                "No app found to open this file (mimeType=$resolvedMime).",
                e,
            )
        }
    }

    /**
     * Throws unless the file at [uri] exists and can be read.
     *
     * @throws FileOpenException with [Constants.ERROR_INVALID_INPUT] for a
     *   scheme other than content:// and file://, [Constants.ERROR_FILE_NOT_FOUND]
     *   (with the URI as message) if the file doesn't exist, or
     *   [Constants.ERROR_OPEN_FAILED] if it can't be read
     */
    private fun checkReadable(
        context: Context,
        uri: Uri,
    ) {
        try {
            when (uri.scheme) {
                "content" ->
                    context.contentResolver.openFileDescriptor(uri, "r")?.close()
                        ?: throw FileOpenException(Constants.ERROR_OPEN_FAILED, "File is not accessible: $uri")

                "file" -> {
                    val file = File(uri.path ?: throw FileOpenException(Constants.ERROR_INVALID_INPUT, "Invalid file URI: $uri"))
                    if (!file.exists()) throw FileOpenException(Constants.ERROR_FILE_NOT_FOUND, uri.toString())
                    FileInputStream(file).close()
                }

                else -> throw FileOpenException(Constants.ERROR_INVALID_INPUT, "Unsupported URI scheme: ${uri.scheme}")
            }
        } catch (e: FileOpenException) {
            throw e
        } catch (e: FileNotFoundException) {
            // ContentResolver reports a missing row or document this way; for a
            // file:// URI it means the existing file can't be read.
            if (uri.scheme == "content") throw FileOpenException(Constants.ERROR_FILE_NOT_FOUND, uri.toString(), e)
            throw FileOpenException(Constants.ERROR_OPEN_FAILED, "File is not accessible: $uri", e)
        } catch (e: Exception) {
            throw FileOpenException(Constants.ERROR_OPEN_FAILED, "File is not accessible: $uri (${e.message})", e)
        }
    }

    /** Returns the FileProvider URI for a readable file:// URI. */
    private fun resolveFileUri(
        context: Context,
        parsedUri: Uri,
    ): Uri {
        val path = parsedUri.path!!
        val file = File(path)

        val authority = "${context.packageName}.file_saver_ffi.fileprovider"
        val hasProvider =
            if (Build.VERSION.SDK_INT >= 33) {
                context.packageManager.resolveContentProvider(
                    authority,
                    PackageManager.ComponentInfoFlags.of(0),
                ) != null
            } else {
                @Suppress("DEPRECATION")
                context.packageManager.resolveContentProvider(authority, 0) != null
            }

        if (!hasProvider) {
            throw FileOpenException(
                Constants.ERROR_OPEN_FAILED,
                "This app must configure a FileProvider to open file:// URIs. " +
                    "See Android Configuration: $androidConfigDocUrl",
            )
        }

        return try {
            FileProvider.getUriForFile(context, authority, file)
        } catch (e: IllegalArgumentException) {
            throw FileOpenException(
                Constants.ERROR_OPEN_FAILED,
                "The FileProvider paths don't cover $path. " +
                    "Update your FileProvider paths XML to include this location. " +
                    "See Android Configuration: $androidConfigDocUrl",
                e,
            )
        }
    }
}
