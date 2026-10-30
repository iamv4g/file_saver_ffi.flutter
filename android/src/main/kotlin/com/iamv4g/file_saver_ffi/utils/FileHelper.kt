package com.iamv4g.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.net.toUri
import com.iamv4g.file_saver_ffi.models.FileType
import com.iamv4g.file_saver_ffi.models.SaveLocation
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.ensureActive
import kotlinx.coroutines.withContext
import java.io.File
import java.io.FileInputStream
import java.io.FileNotFoundException
import java.io.InputStream
import java.io.OutputStream

object FileHelper {
    /**
     * Ensures directory exists, creating it if necessary
     *
     * @param directory Directory to ensure exists
     * @return Result with success or error
     *
     */
    suspend fun ensureDirectoryExists(directory: File): Result<Unit> =
        withContext(Dispatchers.IO) {
            try {
                when {
                    // Directory already exists
                    directory.exists() && directory.isDirectory -> {
                        Result.success(Unit)
                    }

                    // Path exists but is a file (not directory)
                    directory.exists() && !directory.isDirectory -> {
                        Result.failure(
                            IllegalStateException("Path exists but is not a directory: ${directory.absolutePath}"),
                        )
                    }

                    // Directory doesn't exist - create it
                    else -> {
                        val created = directory.mkdirs()
                        if (created || directory.exists()) {
                            Result.success(Unit)
                        } else {
                            Result.failure(
                                IllegalStateException("Failed to create directory: ${directory.absolutePath}"),
                            )
                        }
                    }
                }
            } catch (e: Exception) {
                Result.failure(e)
            }
        }

    /**
     * Builds full file name with extension
     *
     * @param fileName File name without extension
     * @param extension File extension
     * @return Full file name
     *
     * Examples:
     * - ("video", "mp4") → "video.mp4"
     * - ("video", ".mp4") → "video.mp4"
     * - ("video.backup", "mp4") → "video.backup.mp4"
     */
    fun buildFileName(
        fileName: String,
        extension: String,
    ): String {
        val ext = extension.removePrefix(".").trim()
        return if (ext.isNotEmpty()) {
            "$fileName.$ext"
        } else {
            fileName
        }
    }

    /**
     * The MediaStore collection and `RELATIVE_PATH` for a save on Android 10+.
     *
     * The collection follows the MIME type, not the location: MediaProvider
     * rejects a MIME type that doesn't belong to the collection, so a video
     * saved to DCIM must go to the Video collection, not Images. Other files
     * use the Downloads collection.
     *
     * Which top-level directories a collection accepts is left to
     * MediaProvider, because it differs between Android versions (Android 10
     * rejects a video in Pictures/, Android 16 accepts it). A rejected
     * combination fails the insert with an [IllegalArgumentException].
     *
     * @throws IllegalArgumentException if [subDir] has a `..` segment
     */
    @RequiresApi(Build.VERSION_CODES.Q)
    fun scopedStoreTargetFor(
        saveLocation: SaveLocation,
        subDir: String?,
        fileType: FileType,
    ): Pair<Uri, String> {
        validateSubDir(subDir)
        val baseDir = directoryNameFor(saveLocation)
        val dirPath = if (subDir.isNullOrBlank()) baseDir else "$baseDir/$subDir"
        val volume = MediaStore.VOLUME_EXTERNAL_PRIMARY

        val collection =
            when {
                // Downloads takes any file type.
                saveLocation == SaveLocation.DOWNLOADS -> MediaStore.Downloads.getContentUri(volume)
                fileType.isImage -> MediaStore.Images.Media.getContentUri(volume)
                fileType.isVideo -> MediaStore.Video.Media.getContentUri(volume)
                fileType.isAudio -> MediaStore.Audio.Media.getContentUri(volume)
                else -> MediaStore.Downloads.getContentUri(volume)
            }
        return collection to dirPath
    }

    /**
     * The public directory for a save on Android 9 and below.
     *
     * @throws IllegalArgumentException if [subDir] has a `..` segment
     */
    fun legacyStoreDirectoryFor(
        saveLocation: SaveLocation,
        subDir: String?,
    ): File {
        validateSubDir(subDir)
        val publicDir = Environment.getExternalStoragePublicDirectory(directoryNameFor(saveLocation))
        return File(publicDir, subDir ?: "")
    }

    private fun directoryNameFor(saveLocation: SaveLocation): String =
        when (saveLocation) {
            SaveLocation.PICTURES -> Environment.DIRECTORY_PICTURES
            SaveLocation.MOVIES -> Environment.DIRECTORY_MOVIES
            SaveLocation.MUSIC -> Environment.DIRECTORY_MUSIC
            SaveLocation.DOWNLOADS -> Environment.DIRECTORY_DOWNLOADS
            SaveLocation.DCIM -> Environment.DIRECTORY_DCIM
        }

    /** Rejects a [subDir] that could point outside its public directory. */
    private fun validateSubDir(subDir: String?) {
        if (subDir != null && subDir.split('/', '\\').any { it == ".." }) {
            throw IllegalArgumentException("subDir must not contain '..': $subDir")
        }
    }

    /**
     * Writes data to output stream with real-time progress
     *
     * @param outputStream Output stream from MediaStore
     * @param data File data to write
     * @param onProgress Optional suspend callback receiving progress from 0.0 to 1.0
     */
    suspend fun writeStream(
        outputStream: OutputStream,
        data: ByteArray,
        onProgress: (suspend (Double) -> Unit)?,
    ) = withContext(Dispatchers.IO) {
        outputStream.use { stream ->
            var bytesWritten = 0L
            val chunkSize = Constants.CHUNK_SIZE
            val totalBytes = data.size.toLong()

            while (bytesWritten < totalBytes) {
                // Check for cancellation before each chunk
                ensureActive()

                // Calculate chunk size
                val remainingBytes = (totalBytes - bytesWritten).toInt()
                val currentChunkSize = minOf(remainingBytes, chunkSize)

                // Write chunk
                stream.write(data, bytesWritten.toInt(), currentChunkSize)

                // Update progress
                bytesWritten += currentChunkSize

                // Report progress (0.0 to 1.0)
                if (onProgress != null) {
                    val progress = bytesWritten.toDouble() / totalBytes.toDouble()
                    onProgress(progress)
                }
            }

            // Flush stream
            stream.flush()
        }
    }

    /** Result of opening a source file */
    data class SourceFile(
        val inputStream: InputStream,
        val totalSize: Long,
    )

    /**
     * Opens a source file from file:// or content:// URI
     *
     * @param context Application context
     * @param filePath File path (file:// or content:// URI)
     * @return SourceFile containing InputStream and total size
     * @throws FileNotFoundException if file not found
     * @throws SecurityException if permission denied
     */
    suspend fun openSourceFile(
        context: Context,
        filePath: String,
    ): SourceFile =
        withContext(Dispatchers.IO) {
            val uri = filePath.toUri()

            when (uri.scheme) {
                "content" -> {
                    // Content URI - use ContentResolver
                    val inputStream =
                        context.contentResolver.openInputStream(uri)
                            ?: throw FileNotFoundException("Cannot open content URI: $filePath")

                    // Get file size from ContentResolver
                    val size =
                        context.contentResolver
                            .query(uri, arrayOf(MediaStore.MediaColumns.SIZE), null, null, null)
                            ?.use { cursor ->
                                if (cursor.moveToFirst()) {
                                    val sizeIndex = cursor.getColumnIndex(MediaStore.MediaColumns.SIZE)
                                    if (sizeIndex >= 0) cursor.getLong(sizeIndex) else 0L
                                } else {
                                    0L
                                }
                            } ?: 0L

                    SourceFile(inputStream, size)
                }

                "file",
                null,
                -> {
                    // File path
                    val path = uri.path ?: filePath
                    val file = File(path)

                    if (!file.exists()) {
                        throw FileNotFoundException("File not found: $path")
                    }

                    SourceFile(FileInputStream(file), file.length())
                }

                else -> {
                    throw IllegalArgumentException("Unsupported URI scheme: ${uri.scheme}")
                }
            }
        }

    /**
     * Copies data from input stream to output stream with real-time progress
     *
     * @param input Source input stream
     * @param output Destination output stream
     * @param totalSize Total size for progress calculation (0 if unknown)
     * @param onProgress Suspend progress callback (0.0 to 1.0)
     */
    suspend fun copyStream(
        input: InputStream,
        output: OutputStream,
        totalSize: Long,
        onProgress: (suspend (Double) -> Unit)?,
    ) = withContext(Dispatchers.IO) {
        input.use { inputStream ->
            output.use { outputStream ->
                val buffer = ByteArray(Constants.CHUNK_SIZE)
                var bytesWritten = 0L

                while (true) {
                    // Check for cancellation before each chunk
                    ensureActive()

                    val bytesRead = inputStream.read(buffer)
                    if (bytesRead == -1) break

                    outputStream.write(buffer, 0, bytesRead)
                    bytesWritten += bytesRead

                    if (onProgress != null && totalSize > 0) {
                        val progress = bytesWritten.toDouble() / totalSize.toDouble()
                        onProgress(minOf(progress, 1.0))
                    }
                }

                outputStream.flush()
            }
        }
    }
}
