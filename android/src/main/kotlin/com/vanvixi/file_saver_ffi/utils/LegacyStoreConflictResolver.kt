package com.vanvixi.file_saver_ffi.utils

import com.vanvixi.file_saver_ffi.exception.FileExistsException
import com.vanvixi.file_saver_ffi.models.ConflictResolution
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

object LegacyStoreConflictResolver {
    /** Outcome of resolving a filesystem name conflict. */
    sealed class Resolution {
        /**
         * Write to [file]. When [replaces] is set (OVERWRITE), [file] is a
         * temporary file that is renamed over [replaces] after a successful write.
         */
        data class Create(
            val file: File,
            val replaces: File? = null,
        ) : Resolution()

        /** Keep the existing file and write nothing (SKIP). */
        data class Existing(
            val file: File,
        ) : Resolution()
    }

    /**
     * Resolve file conflict using filesystem (Android ≤ 9)
     *
     * Nothing is deleted here. OVERWRITE writes to a temporary file in the same
     * directory, which the caller renames over the original after a successful
     * write.
     *
     * @param directory Target directory (must exist)
     * @param baseFileName File name WITHOUT extension
     * @param extension File extension WITHOUT dot
     * @param conflictResolution Strategy
     *
     * @throws FileExistsException if the file exists and [conflictResolution] is FAIL
     */
    suspend fun resolve(
        directory: File,
        baseFileName: String,
        extension: String,
        conflictResolution: ConflictResolution,
    ): Resolution =
        withContext(Dispatchers.IO) {
            val original =
                File(
                    directory,
                    FileHelper.buildFileName(baseFileName, extension),
                )

            if (!original.exists()) {
                return@withContext Resolution.Create(original)
            }

            when (conflictResolution) {
                ConflictResolution.AUTO_RENAME -> {
                    Resolution.Create(autoRename(directory, baseFileName, extension))
                }

                ConflictResolution.OVERWRITE -> {
                    val temp = File(directory, ".${original.name}.${UUID.randomUUID()}.tmp")
                    Resolution.Create(temp, replaces = original)
                }

                ConflictResolution.SKIP -> {
                    Resolution.Existing(original)
                }

                ConflictResolution.FAIL -> {
                    throw FileExistsException("File already exists: ${original.name}")
                }
            }
        }

    private fun autoRename(
        directory: File,
        baseFileName: String,
        extension: String,
    ): File {
        var index = 1
        while (true) {
            val candidate =
                File(
                    directory,
                    "$baseFileName ($index).$extension",
                )

            if (!candidate.exists()) {
                return candidate
            }
            index++
        }
    }
}
