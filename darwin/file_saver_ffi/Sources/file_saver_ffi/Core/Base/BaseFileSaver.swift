import Foundation

#if os(iOS)
import Photos
#endif

protocol BaseFileSaver: AnyObject {
    // MARK: - Hooks for Subclasses

    /// Format validation hook - override in subclasses to validate file type
    /// Default implementation does nothing (no validation)
    func validateFormat(_ fileType: FileType) throws

    #if os(iOS)
    /// Whether this saver supports Photos Library saves
    /// Default is false (Documents only)
    var supportsPhotosLibrary: Bool { get }

    /// Save data to Photos Library - only Image/Video override this
    /// Default implementation throws unsupportedFormat error
    func saveBytesToPhotos(
        fileData: Data,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String

    /// Save file to Photos Library - only Image/Video override this
    /// Default implementation throws unsupportedFormat error
    func saveFileToPhotos(
        sourceURL: URL,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String
    #endif

    // MARK: - Core Methods (Required)

    func saveBytes(
        fileData: Data,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws

    func saveFile(
        filePath: String,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws

    func saveNetwork(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    )
}

// MARK: - Default Hook Implementations

extension BaseFileSaver {
    func validateFormat(_ fileType: FileType) throws {}

    #if os(iOS)
    var supportsPhotosLibrary: Bool { false }

    func saveBytesToPhotos(
        fileData: Data,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String {
        throw FileSaverError.unsupportedFormat("This file type cannot be saved to Photos Library")
    }

    func saveFileToPhotos(
        sourceURL: URL,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String {
        throw FileSaverError.unsupportedFormat("This file type cannot be saved to Photos Library")
    }
    #endif
}

// MARK: - Helper Methods

extension BaseFileSaver {
    func validateFileData(_ fileData: Data) throws {
        guard !fileData.isEmpty else {
            throw FileSaverError.invalidInput("File data is empty")
        }
    }

    func buildFileName(base: String, extension ext: String) -> String {
        return FileHelper.buildFileName(fileName: base, extension: ext)
    }

    #if os(iOS)
    func findOrCreateAlbum(name: String) throws -> PHAssetCollection {
        return try PhotosHelper.findOrCreateAlbum(name: name)
    }
    #endif

    /// Resolves target directory based on save location and optional subdirectory
    func resolveTargetDirectory(saveLocation: SaveLocation, subDir: String?) throws -> URL {
        #if os(iOS)
        var targetDir = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        #elseif os(macOS)
        var targetDir = saveLocation.directoryURL
        #endif

        if let subDir = subDir {
            targetDir = targetDir.appendingPathComponent(subDir)
        }
        try FileHelper.ensureDirectoryExists(at: targetDir)
        return targetDir
    }

    /// Creates progress mapper for phase-based progress reporting
    func progressMapper(
        from onProgress: ((Double) -> Void)?,
        startProgress: Double,
        endProgress: Double
    ) -> ((Double) -> Void)? {
        return onProgress.map { handler in
            { phaseProgress in
                handler(startProgress + phaseProgress * (endProgress - startProgress))
            }
        }
    }

    #if os(iOS)
    /// Handles Photos permission and conflict resolution.
    /// Nothing is deleted here: for `overwrite` the outcome carries the asset to
    /// delete after the new one has been saved.
    func handlePhotosSetup(
        fileName: String,
        subDir: String?,
        conflictResolution: ConflictResolution
    ) throws -> (hasReadAccess: Bool, outcome: PhotosConflictOutcome) {
        let hasReadAccess = try PhotosHelper.requestPermission(needAlbum: subDir != nil)
        let outcome = try PhotosHelper.handleConflictResolution(
            fileName: fileName,
            subDir: subDir,
            conflictResolution: conflictResolution,
            hasReadAccess: hasReadAccess
        )
        return (hasReadAccess, outcome)
    }
    #endif
}

// MARK: - Shared saveBytes Implementation

extension BaseFileSaver {
    func saveBytesImpl(
        fileData: Data,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        try validateFormat(fileType)
        try validateFileData(fileData)

        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        #if os(iOS)
        let effectiveLocation = supportsPhotosLibrary ? saveLocation : .documents

        switch effectiveLocation {
        case .documents:
            try saveBytesToDocuments(
                fileData: fileData,
                fileName: fileName,
                saveLocation: saveLocation,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: onProgress,
                onSuccess: onSuccess,
                cancellationToken: cancellationToken
            )

        case .photos:
            onProgress?(0.0)

            let (hasReadAccess, outcome) = try handlePhotosSetup(
                fileName: fileName,
                subDir: subDir,
                conflictResolution: conflictResolution
            )

            if case .existing(let existingUri) = outcome {
                onProgress?(1.0)
                onSuccess(existingUri)
                return
            }

            let uri = try saveBytesToPhotos(
                fileData: fileData,
                fileName: fileName,
                albumName: hasReadAccess ? subDir : nil,
                onProgress: onProgress
            )
            PhotosHelper.deleteReplacedAsset(outcome)
            onProgress?(1.0)
            onSuccess(uri)
        }
        #elseif os(macOS)
        try saveBytesToDocuments(
            fileData: fileData,
            fileName: fileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            cancellationToken: cancellationToken
        )
        #endif
    }

    private func saveBytesToDocuments(
        fileData: Data,
        fileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        let targetDir = try resolveTargetDirectory(saveLocation: saveLocation, subDir: subDir)
        let target = try FileManagerConflictResolver.resolveConflict(
            directory: targetDir,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        if case .existing(let existingURL) = target {
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            return
        }

        do {
            try FileHelper.writeFileWithProgress(
                data: fileData,
                to: target.writeURL,
                onProgress: onProgress,
                cancellationToken: cancellationToken
            )
        } catch {
            target.discard()
            throw error
        }

        onSuccess(try target.commit().absoluteString)
    }
}

// MARK: - Shared saveFile Implementation

extension BaseFileSaver {
    func saveFileImpl(
        filePath: String,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        try validateFormat(fileType)

        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        #if os(iOS)
        let effectiveLocation = supportsPhotosLibrary ? saveLocation : .documents

        switch effectiveLocation {
        case .documents:
            try saveFileToDocuments(
                filePath: filePath,
                fileName: fileName,
                saveLocation: saveLocation,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: onProgress,
                onSuccess: onSuccess,
                cancellationToken: cancellationToken
            )

        case .photos:
            let downloadProgressHandler = progressMapper(from: onProgress, startProgress: 0.0, endProgress: 0.8)

            let (hasReadAccess, outcome) = try handlePhotosSetup(
                fileName: fileName,
                subDir: subDir,
                conflictResolution: conflictResolution
            )

            if case .existing(let existingUri) = outcome {
                onProgress?(1.0)
                onSuccess(existingUri)
                return
            }

            let sourceFile = try FileHelper.openSourceFile(
                at: filePath,
                onDownloadProgress: downloadProgressHandler
            )
            defer { sourceFile.close() }

            onProgress?(0.8)

            let uri = try saveFileToPhotos(
                sourceURL: sourceFile.url,
                fileName: fileName,
                albumName: hasReadAccess ? subDir : nil,
                onProgress: onProgress
            )
            PhotosHelper.deleteReplacedAsset(outcome)
            onProgress?(1.0)
            onSuccess(uri)
        }
        #elseif os(macOS)
        try saveFileToDocuments(
            filePath: filePath,
            fileName: fileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            cancellationToken: cancellationToken
        )
        #endif
    }

    private func saveFileToDocuments(
        filePath: String,
        fileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        let targetDir = try resolveTargetDirectory(saveLocation: saveLocation, subDir: subDir)
        let target = try FileManagerConflictResolver.resolveConflict(
            directory: targetDir,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        // Resolve before opening the source so a skip never reads it (or waits
        // for an iCloud download).
        if case .existing(let existingURL) = target {
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            return
        }

        let downloadProgressHandler = progressMapper(from: onProgress, startProgress: 0.0, endProgress: 0.8)

        let sourceFile = try FileHelper.openSourceFile(
            at: filePath,
            onDownloadProgress: downloadProgressHandler
        )
        defer { sourceFile.close() }

        let copyProgressHandler = progressMapper(from: onProgress, startProgress: 0.8, endProgress: 1.0)

        do {
            try FileHelper.copyFileWithProgress(
                from: sourceFile.handle,
                to: target.writeURL,
                totalSize: sourceFile.totalSize,
                onProgress: copyProgressHandler,
                cancellationToken: cancellationToken
            )
        } catch {
            target.discard()
            throw error
        }

        onSuccess(try target.commit().absoluteString)
    }
}
