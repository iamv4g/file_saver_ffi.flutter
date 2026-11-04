import Foundation

#if os(iOS)
import Photos
#endif

/// Saves bytes, a file or a download, for files of every type: to a directory
/// (Documents on iOS, the save location on macOS), to a user-picked directory,
/// or, for images and videos on iOS, to the Photos Library.
final class SaveEngine {}

// MARK: - Helper Methods

extension SaveEngine {
    func validateFileData(_ fileData: Data) throws {
        guard !fileData.isEmpty else {
            throw FileSaverError.invalidInput("File data is empty")
        }
    }

    func buildFileName(base: String, extension ext: String) -> String {
        return FileHelper.buildFileName(fileName: base, extension: ext)
    }

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

    /// Throws for a file type the Photos Library doesn't take: only images and
    /// videos can be saved to `.photos`, by every API.
    func checkPhotosSupport(saveLocation: SaveLocation, fileType: FileType) throws {
        guard saveLocation == .photos, !PhotosHelper.supports(fileType) else { return }
        throw FileSaverError.photosUnsupported(fileType)
    }
    #endif
}

// MARK: - Shared saveBytes Implementation

extension SaveEngine {
    func saveBytes(
        fileData: Data,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ProgressHandler?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        try validateFileData(fileData)

        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        #if os(iOS)
        try checkPhotosSupport(saveLocation: saveLocation, fileType: fileType)

        switch saveLocation {
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
            let (hasReadAccess, outcome) = try handlePhotosSetup(
                fileName: fileName,
                subDir: subDir,
                conflictResolution: conflictResolution
            )

            if case .existing(let existingUri) = outcome {
                onSuccess(existingUri)
                return
            }

            // The permission dialog can stay open for a while. Once the asset
            // is being added, it can't be stopped.
            try cancellationToken?.throwIfCancelled()
            let uri = try PhotosHelper.createAsset(
                from: .data(fileData),
                fileType: fileType,
                fileName: fileName,
                albumName: hasReadAccess ? subDir : nil
            )
            PhotosHelper.deleteReplacedAsset(outcome)
            // Photos takes the whole file at once.
            let size = Int64(fileData.count)
            onProgress?(size, size)
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
        onProgress: ProgressHandler?,
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

extension SaveEngine {
    func saveFile(
        filePath: String,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ProgressHandler?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {

        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        #if os(iOS)
        try checkPhotosSupport(saveLocation: saveLocation, fileType: fileType)

        switch saveLocation {
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
            let (hasReadAccess, outcome) = try handlePhotosSetup(
                fileName: fileName,
                subDir: subDir,
                conflictResolution: conflictResolution
            )

            if case .existing(let existingUri) = outcome {
                onSuccess(existingUri)
                return
            }

            try cancellationToken?.throwIfCancelled()
            let sourceFile = try FileHelper.openSourceFile(at: filePath, cancellationToken: cancellationToken)
            defer { sourceFile.close() }

            // Once the asset is being added, it can't be stopped.
            try cancellationToken?.throwIfCancelled()
            let uri = try PhotosHelper.createAsset(
                from: .file(sourceFile.url),
                fileType: fileType,
                fileName: fileName,
                albumName: hasReadAccess ? subDir : nil
            )
            PhotosHelper.deleteReplacedAsset(outcome)
            // Photos takes the whole file at once.
            onProgress?(sourceFile.totalSize, sourceFile.totalSize)
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
        onProgress: ProgressHandler?,
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
            onSuccess(existingURL.absoluteString)
            return
        }

        let sourceFile: FileHelper.SourceFile
        do {
            sourceFile = try FileHelper.openSourceFile(at: filePath, cancellationToken: cancellationToken)
        } catch {
            target.discard()
            throw error
        }
        defer { sourceFile.close() }

        do {
            try FileHelper.copyFileWithProgress(
                from: sourceFile.handle,
                to: target.writeURL,
                totalSize: sourceFile.totalSize,
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
