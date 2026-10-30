package com.iamv4g.file_saver_ffi.core

import android.content.Context
import com.iamv4g.file_saver_ffi.core.base.BaseFileSaver
import com.iamv4g.file_saver_ffi.core.base.SaveEntryFactory
import com.iamv4g.file_saver_ffi.exception.UnsupportedFormatException
import com.iamv4g.file_saver_ffi.models.ConflictResolution
import com.iamv4g.file_saver_ffi.models.SaveProgressEvent
import com.iamv4g.file_saver_ffi.utils.Constants
import com.iamv4g.file_saver_ffi.utils.FormatValidator
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.flow.Flow
import kotlinx.coroutines.flow.FlowCollector
import kotlinx.coroutines.flow.flow
import kotlinx.coroutines.flow.flowOn

/**
 * Saver for audio files with format validation.
 * Validates audio format before saving to MediaStore.
 */
class AudioSaver(
    context: Context,
) : BaseFileSaver(context) {
    override fun saveBytes(
        fileData: ByteArray,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        flow {
            if (!validateAudioFormat(entryFactory)) return@flow

            super
                .saveBytes(fileData, entryFactory, conflictResolution)
                .collect { event -> emit(event) }
        }.flowOn(Dispatchers.IO)

    override fun saveFile(
        filePath: String,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        flow {
            if (!validateAudioFormat(entryFactory)) return@flow

            super
                .saveFile(filePath, entryFactory, conflictResolution)
                .collect { event -> emit(event) }
        }.flowOn(Dispatchers.IO)

    override fun saveNetwork(
        url: String,
        headersJson: String?,
        timeoutMs: Int,
        entryFactory: SaveEntryFactory,
        conflictResolution: ConflictResolution,
    ): Flow<SaveProgressEvent> =
        flow {
            if (!validateAudioFormat(entryFactory)) return@flow

            super
                .saveNetwork(url, headersJson, timeoutMs, entryFactory, conflictResolution)
                .collect { event -> emit(event) }
        }.flowOn(Dispatchers.IO)

    /**
     * Validates audio format for MediaStore entries.
     * SAF entries don't require format validation.
     *
     * @return true if valid or SAF, false if invalid (error emitted)
     */
    private suspend fun FlowCollector<SaveProgressEvent>.validateAudioFormat(entryFactory: SaveEntryFactory): Boolean {
        if (entryFactory is SaveEntryFactory.MediaStore) {
            try {
                FormatValidator.validateAudioFormat(entryFactory.fileType)
            } catch (e: UnsupportedFormatException) {
                emit(
                    SaveProgressEvent.Error(
                        Constants.ERROR_UNSUPPORTED_FORMAT,
                        e.message ?: "Unsupported format: ${entryFactory.fileType.ext}",
                    ),
                )
                return false
            }
        }
        return true
    }
}
