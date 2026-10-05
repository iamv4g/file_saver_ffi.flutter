import Foundation

#if os(iOS)
import Photos
#endif

class VideoSaver: BaseFileSaver {
    // MARK: - Hooks

    #if os(iOS)
    var supportsPhotosLibrary: Bool { true }
    #endif

    func validateFormat(_ fileType: FileType) throws {
        try FormatValidator.validateVideoFormat(fileType)
    }

    #if os(iOS)
    // MARK: - Photos Library Implementation

    func saveBytesToPhotos(
        fileData: Data,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String {
        // Videos must be saved from a file URL (not directly from data)
        let tempURL = FileManager.default.temporaryDirectory.appendingPathComponent(fileName)
        try fileData.write(to: tempURL)
        defer { try? FileManager.default.removeItem(at: tempURL) }

        return try saveVideoToPhotosLibrary(
            sourceURL: tempURL,
            fileName: fileName,
            albumName: albumName
        )
    }

    func saveFileToPhotos(
        sourceURL: URL,
        fileName: String,
        albumName: String?,
        onProgress: ((Double) -> Void)?
    ) throws -> String {
        return try saveVideoToPhotosLibrary(
            sourceURL: sourceURL,
            fileName: fileName,
            albumName: albumName
        )
    }

    private func saveVideoToPhotosLibrary(
        sourceURL: URL,
        fileName: String,
        albumName: String?
    ) throws -> String {
        let album = try albumName.map { try findOrCreateAlbum(name: $0) }

        var assetId: String?

        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileName
                request.addResource(with: .video, fileURL: sourceURL, options: options)

                if let album = album {
                    if let placeholder = request.placeholderForCreatedAsset {
                        let albumChangeRequest = PHAssetCollectionChangeRequest(for: album)
                        albumChangeRequest?.addAssets([placeholder] as NSArray)
                    }
                }

                assetId = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw FileSaverError.fileIO("Failed to save video: \(error.localizedDescription)")
        }

        guard let assetId = assetId else {
            throw FileSaverError.fileIO("Failed to save video to Photos library")
        }

        return "ph://\(assetId)"
    }
    #endif

    // MARK: - Core Methods (Delegate to Impl)

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
    ) throws {
        try saveBytesImpl(
            fileData: fileData,
            fileType: fileType,
            baseFileName: baseFileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            cancellationToken: cancellationToken
        )
    }

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
    ) throws {
        try saveFileImpl(
            filePath: filePath,
            fileType: fileType,
            baseFileName: baseFileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            cancellationToken: cancellationToken
        )
    }

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
    ) {
        // Validate format first
        do {
            try validateFormat(fileType)
        } catch let error as FileSaverError {
            onError(error.code, error.message)
            onComplete()
            return
        } catch {
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
            return
        }

        saveNetworkImpl(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            fileType: fileType,
            baseFileName: baseFileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            onError: onError,
            onCancelled: onCancelled,
            onCancelHandlerReady: onCancelHandlerReady,
            onComplete: onComplete,
            cancellationToken: cancellationToken
        )
    }
}
