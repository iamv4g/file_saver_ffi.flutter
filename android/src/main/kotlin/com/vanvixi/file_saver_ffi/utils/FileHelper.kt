package com.vanvixi.file_saver_ffi.utils

import android.content.Context
import android.net.Uri
import android.os.Build
import android.os.Environment
import android.provider.MediaStore
import androidx.annotation.RequiresApi
import androidx.core.net.toUri
import com.vanvixi.file_saver_ffi.models.SaveLocation
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

    @RequiresApi(Build.VERSION_CODES.Q)
    fun scopedStoreTargetFor(
        saveLocation: SaveLocation,
        subDir: String?,
    ): Pair<Uri, String> {
        fun buildDir(
            defaultDir: String,
            subDir: String?,
        ) = if (subDir.isNullOrBlank()) defaultDir else "$defaultDir/$subDir"

        return when (saveLocation) {
            SaveLocation.PICTURES -> {
                val uri =
                    MediaStore.Images.Media.getContentUri(
                        MediaStore.VOLUME_EXTERNAL_PRIMARY,
                    )
                uri to buildDir(Environment.DIRECTORY_PICTURES, subDir)
            }

            SaveLocation.MOVIES -> {
                val uri =
                    MediaStore.Video.Media.getContentUri(
                        MediaStore.VOLUME_EXTERNAL_PRIMARY,
                    )
                uri to buildDir(Environment.DIRECTORY_MOVIES, subDir)
            }

            SaveLocation.MUSIC -> {
                val uri =
                    MediaStore.Audio.Media.getContentUri(
                        MediaStore.VOLUME_EXTERNAL_PRIMARY,
                    )
                uri to buildDir(Environment.DIRECTORY_MUSIC, subDir)
            }

            SaveLocation.DOWNLOADS -> {
                val uri =
                    MediaStore.Downloads.getContentUri(
                        MediaStore.VOLUME_EXTERNAL_PRIMARY,
                    )
                uri to buildDir(Environment.DIRECTORY_DOWNLOADS, subDir)
            }

            SaveLocation.DCIM -> {
                val uri =
                    MediaStore.Images.Media.getContentUri(
                        MediaStore.VOLUME_EXTERNAL_PRIMARY,
                    )
                uri to buildDir(Environment.DIRECTORY_DCIM, subDir)
            }
        }
    }

    fun legacyStoreDirectoryFor(
        saveLocation: SaveLocation,
        subDir: String?,
    ): File {
        val baseDir =
            when (saveLocation) {
                SaveLocation.PICTURES -> Environment.DIRECTORY_PICTURES
                SaveLocation.MOVIES -> Environment.DIRECTORY_MOVIES
                SaveLocation.MUSIC -> Environment.DIRECTORY_MUSIC
                SaveLocation.DOWNLOADS -> Environment.DIRECTORY_DOWNLOADS
                SaveLocation.DCIM -> Environment.DIRECTORY_DCIM
            }

        val publicDir = Environment.getExternalStoragePublicDirectory(baseDir)
        return File(publicDir, subDir ?: "")
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
