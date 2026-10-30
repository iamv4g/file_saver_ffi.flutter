import Foundation

class FileSaver {
    let imageSaver = ImageSaver()
    let videoSaver = VideoSaver()
    let audioSaver = AudioSaver()
    let customFileSaver = CustomFileSaver()

    // MARK: - Standard Save Methods

    func saveBytes(
        fileData: Data,
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        saveLocationValue: Int,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter) else { return }

        let fileType = FileHelper.getFileType(ext: ext, mimeType: mimeType)
        let saveLocation = SaveLocation.fromInt(saveLocationValue)
        let saver = getSaver(for: fileType)

        do {
            try saver.saveBytes(
                fileData: fileData,
                fileType: fileType,
                baseFileName: baseFileName,
                saveLocation: saveLocation,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: { reporter.sendProgress($0) },
                onSuccess: { reporter.sendSuccess(uri: $0) },
                cancellationToken: cancellationToken
            )
        } catch {
            handleError(error, reporter: reporter)
        }
    }

    func saveFile(
        filePath: String,
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        saveLocationValue: Int,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter) else { return }

        let fileType = FileHelper.getFileType(ext: ext, mimeType: mimeType)
        let saveLocation = SaveLocation.fromInt(saveLocationValue)
        let saver = getSaver(for: fileType)

        do {
            try saver.saveFile(
                filePath: filePath,
                fileType: fileType,
                baseFileName: baseFileName,
                saveLocation: saveLocation,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: { reporter.sendProgress($0) },
                onSuccess: { reporter.sendSuccess(uri: $0) },
                cancellationToken: cancellationToken
            )
        } catch {
            handleError(error, reporter: reporter)
        }
    }

    func saveNetwork(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        saveLocationValue: Int,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter, onComplete: onComplete) else { return }

        let fileType = FileHelper.getFileType(ext: ext, mimeType: mimeType)
        let saveLocation = SaveLocation.fromInt(saveLocationValue)
        let saver = getSaver(for: fileType)

        saver.saveNetwork(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            fileType: fileType,
            baseFileName: baseFileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: { reporter.sendProgress($0) },
            onSuccess: { reporter.sendSuccess(uri: $0) },
            onError: { reporter.sendError(code: $0, message: $1) },
            onCancelled: { reporter.sendCancelled() },
            onCancelHandlerReady: onCancelHandlerReady,
            onComplete: onComplete,
            cancellationToken: cancellationToken
        )
    }

    // MARK: - Save*As Methods (User-Selected Directory)

    func saveBytesAs(
        fileData: Data,
        directoryUri: String,
        baseFileName: String,
        extension ext: String,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter) else { return }
        guard let directoryURL = parseDirectoryURL(directoryUri, reporter: reporter) else { return }

        let fileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)

        do {
            try customFileSaver.saveBytesAs(
                fileData: fileData,
                directoryURL: directoryURL,
                fileName: fileName,
                conflictResolution: conflictResolution,
                onProgress: { reporter.sendProgress($0) },
                onSuccess: { reporter.sendSuccess(uri: $0) },
                cancellationToken: cancellationToken
            )
        } catch {
            handleError(error, reporter: reporter)
        }
    }

    func saveFileAs(
        filePath: String,
        directoryUri: String,
        baseFileName: String,
        extension ext: String,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter) else { return }
        guard let directoryURL = parseDirectoryURL(directoryUri, reporter: reporter) else { return }

        let fileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)

        do {
            try customFileSaver.saveFileAs(
                filePath: filePath,
                directoryURL: directoryURL,
                fileName: fileName,
                conflictResolution: conflictResolution,
                onProgress: { reporter.sendProgress($0) },
                onSuccess: { reporter.sendSuccess(uri: $0) },
                cancellationToken: cancellationToken
            )
        } catch {
            handleError(error, reporter: reporter)
        }
    }

    func saveNetworkAs(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        directoryUri: String,
        baseFileName: String,
        extension ext: String,
        conflictMode: Int,
        reporter: ProgressReporter,
        cancellationToken: CancellationToken? = nil,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void
    ) {
        guard let conflictResolution = parseConflictResolution(conflictMode, reporter: reporter, onComplete: onComplete) else { return }
        guard let directoryURL = parseDirectoryURL(directoryUri, reporter: reporter, onComplete: onComplete) else { return }

        let fileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)

        customFileSaver.saveNetworkAs(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            directoryURL: directoryURL,
            fileName: fileName,
            conflictResolution: conflictResolution,
            onProgress: { reporter.sendProgress($0) },
            onSuccess: { reporter.sendSuccess(uri: $0) },
            onError: { reporter.sendError(code: $0, message: $1) },
            onCancelled: { reporter.sendCancelled() },
            onCancelHandlerReady: onCancelHandlerReady,
            onComplete: onComplete,
            cancellationToken: cancellationToken
        )
    }

    // MARK: - Streaming Write Session

    /// Opens a FileHandle for incremental writing.
    ///
    /// Returns `(writeURL, fileHandle, commit)`. Chunks go to `writeURL`; the caller
    /// invokes `commit()` on close, which makes the written file the saved file and
    /// returns its URI, and deletes `writeURL` on cancel. `writeURL` is never an
    /// existing file, so a cancelled `overwrite` keeps the original.
    ///
    /// - On iOS + photos: `writeURL` is a temp file and `commit()` adds it to the
    ///   Photos Library (then deletes a replaced asset for `overwrite`).
    /// - On iOS + documents / macOS: `writeURL` is the new file, or a temp file next
    ///   to the original for `overwrite`, which `commit()` replaces.
    ///
    /// - Throws: `FileSaverError.writeSessionSkipped` for `skip` when the file exists.
    func openWriteSession(
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        saveLocationValue: Int,
        conflictMode: Int
    ) throws -> (fileURL: URL, fileHandle: FileHandle, commit: () throws -> String) {
        let saveLocation = SaveLocation.fromInt(saveLocationValue)

        #if os(iOS)
        if saveLocation == .photos {
            return try openWriteSessionForPhotos(
                baseFileName: baseFileName,
                extension: ext,
                mimeType: mimeType,
                subDir: subDir,
                conflictMode: conflictMode
            )
        }
        var targetDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #elseif os(macOS)
        var targetDir = saveLocation.directoryURL
        #endif

        if let sub = subDir, !sub.isEmpty {
            targetDir = targetDir.appendingPathComponent(sub)
        }
        try FileHelper.ensureDirectoryExists(at: targetDir)

        let fullFileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)
        return try openFileManagerWriteSession(
            directory: targetDir,
            fileName: fullFileName,
            conflictResolution: ConflictResolution.fromInt(conflictMode)
        )
    }

    /// Resolves the conflict in `directory` and opens a handle on the file to write.
    /// Shared by `openWriteSession` (non-Photos) and `openWriteSessionAs`.
    private func openFileManagerWriteSession(
        directory: URL,
        fileName: String,
        conflictResolution: ConflictResolution
    ) throws -> (fileURL: URL, fileHandle: FileHandle, commit: () throws -> String) {
        let target = try FileManagerConflictResolver.resolveConflict(
            directory: directory,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        if case .existing = target {
            throw FileSaverError.writeSessionSkipped
        }

        let writeURL = target.writeURL
        let fileHandle: FileHandle
        do {
            fileHandle = try FileHelper.openForWriting(writeURL)
        } catch {
            target.discard()
            throw error
        }
        return (writeURL, fileHandle, { try target.commit().absoluteString })
    }

    #if os(iOS)
    /// Opens a write session targeting the Photos Library.
    /// Chunks are written to a temp file. Returns a `photosCommit` closure that the caller
    /// must invoke on `closeWrite` — the closure commits the temp file to the Photos Library
    /// and deletes it, returning the `ph://` asset URI.
    private func openWriteSessionForPhotos(
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        conflictMode: Int
    ) throws -> (fileURL: URL, fileHandle: FileHandle, commit: () throws -> String) {
        let fileType = FileHelper.getFileType(ext: ext, mimeType: mimeType)
        let saver = getSaver(for: fileType)

        try saver.checkPhotosSupport(saveLocation: .photos, fileType: fileType)

        let fullFileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)
        let conflictResolution = ConflictResolution.fromInt(conflictMode)

        let hasReadAccess = try PhotosHelper.requestPermission(needAlbum: subDir != nil)
        let outcome = try PhotosHelper.handleConflictResolution(
            fileName: fullFileName,
            subDir: subDir,
            conflictResolution: conflictResolution,
            hasReadAccess: hasReadAccess
        )

        if case .existing = outcome {
            throw FileSaverError.writeSessionSkipped
        }

        let albumName: String? = hasReadAccess ? subDir : nil

        // Write chunks to a temp file; commit to Photos Library on close.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        let fileHandle = try FileHelper.openForWriting(tmpURL)

        // Closure captures everything needed for commit; caller invokes on closeWrite.
        let photosCommit: () throws -> String = {
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            let uri = try saver.saveFileToPhotos(
                sourceURL: tmpURL,
                fileName: fullFileName,
                albumName: albumName,
                onProgress: nil
            )
            PhotosHelper.deleteReplacedAsset(outcome)
            return uri
        }

        return (tmpURL, fileHandle, photosCommit)
    }
    #endif

    /// Opens a FileHandle for incremental writing to a user-selected directory.
    func openWriteSessionAs(
        directoryUri: String,
        baseFileName: String,
        extension ext: String,
        conflictMode: Int
    ) throws -> (fileURL: URL, fileHandle: FileHandle, commit: () throws -> String) {
        guard let dirURL = URL(string: directoryUri) else {
            throw FileSaverError.fileIO("Invalid directory URI: \(directoryUri)")
        }
        return try openFileManagerWriteSession(
            directory: dirURL,
            fileName: FileHelper.buildFileName(fileName: baseFileName, extension: ext),
            conflictResolution: ConflictResolution.fromInt(conflictMode)
        )
    }

    // MARK: - Private Helpers

    private func parseConflictResolution(
        _ conflictMode: Int,
        reporter: ProgressReporter,
        onComplete: (() -> Void)? = nil
    ) -> ConflictResolution? {
        guard let resolution = ConflictResolution(rawValue: conflictMode) else {
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "Invalid conflict resolution mode: \(conflictMode)"
            )
            onComplete?()
            return nil
        }
        return resolution
    }

    private func getSaver(for fileType: FileType) -> BaseFileSaver {
        switch fileType.category {
        case .image: return imageSaver
        case .video: return videoSaver
        case .audio: return audioSaver
        case .custom: return customFileSaver
        }
    }

    private func parseDirectoryURL(
        _ directoryUri: String,
        reporter: ProgressReporter,
        onComplete: (() -> Void)? = nil
    ) -> URL? {
        guard let url = URL(string: directoryUri) else {
            reporter.sendError(
                code: Constants.errorInvalidInput,
                message: "Invalid directory URI: \(directoryUri)"
            )
            onComplete?()
            return nil
        }
        return url
    }

    private func handleError(_ error: Error, reporter: ProgressReporter) {
        switch error {
        case FileSaverError.cancelled:
            reporter.sendCancelled()
        case let fsError as FileSaverError:
            reporter.sendError(code: fsError.code, message: fsError.message)
        default:
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "Unexpected error: \(error.localizedDescription)"
            )
        }
    }
}
