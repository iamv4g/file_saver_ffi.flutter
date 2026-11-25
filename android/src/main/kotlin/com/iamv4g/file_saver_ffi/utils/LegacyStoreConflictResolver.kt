package com.iamv4g.file_saver_ffi.utils

import com.iamv4g.file_saver_ffi.exception.FileExistsException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext
import java.io.File
import java.util.UUID

object LegacyStoreConflictResolver {
    /** Outcome of resolving a filesystem name conflict. */
    sealed class Resolution {
        /**
         * Write to [file], which exists and is empty. For OVERWRITE
         * ([overwrite]) it is a temporary file, which the commit renames to
         * the requested name.
         */
        data class Create(
            val file: File,
            val overwrite: Boolean = false,
        ) : Resolution()

        /** Keep the existing file and write nothing (SKIP). */
        data class Existing(
            val file: File,
        ) : Resolution()
    }

    /**
     * Resolve file conflict using filesystem (Android ≤ 9)
     *
     * The file to write is created empty, so the name is checked and claimed
     * in one step ([File.createNewFile]) and concurrent saves never pick the
     * same one. Nothing is deleted here: OVERWRITE always writes to a
     * temporary file in the same directory, which the caller renames over
     * the requested name after a successful write.
     *
     * @param directory Target directory (must exist)
     * @param baseFileName File name WITHOUT extension
     * @param extension File extension WITHOUT dot
     * @param conflictResolution Strategy
     *
     * @throws FileExistsException if the file exists and [conflictResolution] is FAIL
     * @throws java.io.IOException if the file can't be created
     */
    suspend fun resolve(
        directory: File,
        baseFileName: String,
        extension: String,
        conflictResolution: ConflictResolution,
    ): Resolution =
        withContext(Dispatchers.IO) {
            val name = FileHelper.buildFileName(baseFileName, extension)

            if (conflictResolution == ConflictResolution.OVERWRITE) {
                val temp = File(directory, ".$name.${UUID.randomUUID()}.tmp").apply { createNewFile() }
                return@withContext Resolution.Create(temp, overwrite = true)
            }

            val original = File(directory, name)
            if (original.createNewFile()) {
                return@withContext Resolution.Create(original)
            }

            when (conflictResolution) {
                ConflictResolution.AUTO_RENAME -> {
                    val renamed = FileHelper.numberedName(baseFileName, extension) { !File(directory, it).createNewFile() }
                    Resolution.Create(File(directory, renamed))
                }

                ConflictResolution.SKIP -> {
                    Resolution.Existing(original)
                }

                ConflictResolution.FAIL -> {
                    throw FileExistsException(original.name)
                }

                ConflictResolution.OVERWRITE -> {
                    error("Handled above")
                }
            }
        }
}
