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
    /// - On iOS + photos: writes to a temp file and returns a `photosCommit` closure.
    ///   The caller must invoke `photosCommit()` on close to add the file to the Photos
    ///   Library and delete the temp file. The closure captures all needed context.
    /// - On iOS + documents / macOS: writes directly to the resolved path; `photosCommit` is nil.
    ///
    /// Returns `(tempOrFinalURL, fileHandle, photosCommit)`.
    func openWriteSession(
        baseFileName: String,
        extension ext: String,
        mimeType: String,
        subDir: String?,
        saveLocationValue: Int,
        conflictMode: Int
    ) throws -> (fileURL: URL, fileHandle: FileHandle, photosCommit: (() throws -> String)?) {
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
        let conflictResolution = ConflictResolution.fromInt(conflictMode)

        if conflictResolution == .skip {
            let targetURL = targetDir.appendingPathComponent(fullFileName)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                throw FileSaverError.writeSessionSkipped
            }
        }

        let fileURL = try FileManagerConflictResolver.resolveConflict(
            directory: targetDir,
            fileName: fullFileName,
            conflictResolution: conflictResolution
        )

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        return (fileURL, fileHandle, nil)
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
    ) throws -> (fileURL: URL, fileHandle: FileHandle, photosCommit: (() throws -> String)?) {
        let fileType = FileHelper.getFileType(ext: ext, mimeType: mimeType)
        let saver = getSaver(for: fileType)

        guard saver.supportsPhotosLibrary else {
            throw FileSaverError.unsupportedFormat(
                ext.uppercased(),
                details: "Only images and videos can be saved to the Photos Library."
            )
        }

        let fullFileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)
        let conflictResolution = ConflictResolution.fromInt(conflictMode)

        let hasReadAccess = try PhotosHelper.requestPermission(needAlbum: subDir != nil)
        let existingUri = try PhotosHelper.handleConflictResolution(
            fileName: fullFileName,
            subDir: subDir,
            conflictResolution: conflictResolution,
            hasReadAccess: hasReadAccess
        )

        if existingUri != nil {
            if conflictResolution == .skip {
                throw FileSaverError.writeSessionSkipped
            }
            throw FileSaverError.fileExists(fullFileName)
        }

        let albumName: String? = hasReadAccess ? subDir : nil

        // Write chunks to a temp file; commit to Photos Library on close.
        let tmpURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension(ext)
        FileManager.default.createFile(atPath: tmpURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: tmpURL)

        // Closure captures everything needed for commit; caller invokes on closeWrite.
        let photosCommit: () throws -> String = {
            defer { try? FileManager.default.removeItem(at: tmpURL) }
            return try saver.saveFileToPhotos(
                sourceURL: tmpURL,
                fileName: fullFileName,
                albumName: albumName,
                onProgress: nil
            )
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
    ) throws -> (URL, FileHandle) {
        guard let dirURL = URL(string: directoryUri) else {
            throw FileSaverError.fileIO("Invalid directory URI: \(directoryUri)")
        }
        let fullFileName = FileHelper.buildFileName(fileName: baseFileName, extension: ext)
        let conflictResolution = ConflictResolution.fromInt(conflictMode)

        if conflictResolution == .skip {
            let targetURL = dirURL.appendingPathComponent(fullFileName)
            if FileManager.default.fileExists(atPath: targetURL.path) {
                throw FileSaverError.writeSessionSkipped
            }
        }

        let fileURL = try FileManagerConflictResolver.resolveConflict(
            directory: dirURL,
            fileName: fullFileName,
            conflictResolution: conflictResolution
        )

        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let fileHandle = try FileHandle(forWritingTo: fileURL)
        return (fileURL, fileHandle)
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
