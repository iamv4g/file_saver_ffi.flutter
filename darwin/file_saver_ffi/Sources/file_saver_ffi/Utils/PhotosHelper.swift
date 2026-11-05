#if os(iOS)
import Foundation
import Photos

class PhotosHelper {
    /// Requests photo library permission from the user.
    ///
    /// Read/write access the app already has (full or limited) is always used,
    /// so conflict resolution works and the saved `ph://` URI can be opened.
    /// Otherwise the dialog asks for `.readWrite` if `needAlbum` is `true`, and
    /// for `.addOnly` if it is `false`.
    ///
    /// - Parameter needAlbum: Whether the save needs `.readWrite`, for album
    ///   support.
    /// - Returns: `true` if read/write access is granted (full or limited),
    ///   `false` if only add-only access is.
    /// - Throws: `FileSaverError.permissionDenied` if the user denies access.
    static func requestPermission(needAlbum: Bool) throws -> Bool {
        let readWrite = authorize(.readWrite, request: needAlbum)
        if readWrite == .authorized || readWrite == .limited {
            return true
        }
        guard !needAlbum, authorize(.addOnly, request: true) == .authorized else {
            throw FileSaverError.permissionDenied("Photo library access denied")
        }
        return false
    }

    /// Returns the status of `accessLevel`, first asking the user if it is
    /// undetermined and `request` is `true`.
    private static func authorize(_ accessLevel: PHAccessLevel, request: Bool) -> PHAuthorizationStatus {
        let status = PHPhotoLibrary.authorizationStatus(for: accessLevel)
        guard request, status == .notDetermined else { return status }
        return waitForAuthorization { PHPhotoLibrary.requestAuthorization(for: accessLevel, handler: $0) }
    }

    /// Blocks the calling (background) thread until `request` reports the
    /// user's answer.
    private static func waitForAuthorization(
        _ request: (@escaping (PHAuthorizationStatus) -> Void) -> Void
    ) -> PHAuthorizationStatus {
        var status = PHAuthorizationStatus.notDetermined
        let semaphore = DispatchSemaphore(value: 0)
        request {
            status = $0
            semaphore.signal()
        }
        semaphore.wait()
        return status
    }

    /// Find or create album with given name
    static func findOrCreateAlbum(name: String) throws -> PHAssetCollection {
        let options = PHFetchOptions()
        options.predicate = NSPredicate(format: "title = %@", name)
        let collections = PHAssetCollection.fetchAssetCollections(with: .album, subtype: .any, options: options)

        if let existing = collections.firstObject {
            return existing
        }

        var albumId: String?
        try PHPhotoLibrary.shared().performChangesAndWait {
            let request = PHAssetCollectionChangeRequest.creationRequestForAssetCollection(withTitle: name)
            albumId = request.placeholderForCreatedAssetCollection.localIdentifier
        }

        guard let albumId = albumId,
              let album = PHAssetCollection.fetchAssetCollections(withLocalIdentifiers: [albumId], options: nil).firstObject else {
            throw FileSaverError.fileIO("Failed to create album: \(name)")
        }

        return album
    }

    /// What `createAsset` adds to the library.
    enum AssetSource {
        case data(Data)
        case file(URL)
    }

    /// Whether the Photos Library takes files of `fileType`: only images and
    /// videos.
    static func supports(_ fileType: FileType) -> Bool {
        fileType.category == .image || fileType.category == .video
    }

    /// Adds an image or a video to the Photos Library, to `albumName` if it is
    /// given, and returns the `ph://` URI of the new asset.
    static func createAsset(
        from source: AssetSource,
        fileType: FileType,
        fileName: String,
        albumName: String?
    ) throws -> String {
        let isVideo = fileType.category == .video
        // Photos takes a video only from a file. The UUID keeps concurrent saves
        // of the same name from overwriting each other's temp file; Photos uses
        // `originalFilename`, not this name.
        if isVideo, case .data(let data) = source {
            let tempURL = FileManager.default.temporaryDirectory
                .appendingPathComponent("\(UUID().uuidString)-\(fileName)")
            try data.write(to: tempURL)
            defer { try? FileManager.default.removeItem(at: tempURL) }
            return try createAsset(from: .file(tempURL), fileType: fileType, fileName: fileName, albumName: albumName)
        }

        let album = try albumName.map { try findOrCreateAlbum(name: $0) }
        let kind = isVideo ? "video" : "image"
        var assetId: String?

        do {
            try PHPhotoLibrary.shared().performChangesAndWait {
                let request = PHAssetCreationRequest.forAsset()
                let options = PHAssetResourceCreationOptions()
                options.originalFilename = fileName
                let type: PHAssetResourceType = isVideo ? .video : .photo
                switch source {
                case .data(let data): request.addResource(with: type, data: data, options: options)
                case .file(let url): request.addResource(with: type, fileURL: url, options: options)
                }

                if let album = album, let placeholder = request.placeholderForCreatedAsset {
                    PHAssetCollectionChangeRequest(for: album)?.addAssets([placeholder] as NSArray)
                }

                assetId = request.placeholderForCreatedAsset?.localIdentifier
            }
        } catch {
            throw FileSaverError.fileIO("Failed to save \(kind): \(error.localizedDescription)")
        }

        guard let assetId = assetId else {
            throw FileSaverError.fileIO("Failed to save \(kind) to Photos library")
        }

        return "ph://\(assetId)"
    }

    /// Handle conflict resolution for Photos Library.
    ///
    /// Nothing is deleted here. For `overwrite` the outcome carries the existing
    /// asset, which `deleteReplacedAsset(_:)` removes after the new asset is saved.
    ///
    /// - Throws: `FileSaverError.fileExists` if the asset exists and
    ///   `conflictResolution` is `.fail`.
    static func handleConflictResolution(
        fileName: String,
        subDir: String?,
        conflictResolution: ConflictResolution,
        hasReadAccess: Bool
    ) throws -> PhotosConflictOutcome {
        // Without read access existing assets can't be looked up.
        guard hasReadAccess, conflictResolution != .autoRename,
              let existing = PhotosConflictResolver.findExistingAsset(fileName: fileName, inAlbum: subDir)
        else {
            return .save(replacing: nil)
        }

        switch conflictResolution {
        case .fail:
            throw FileSaverError.fileExists(fileName)
        case .skip:
            return .existing(uri: "ph://\(existing.localIdentifier)")
        case .overwrite:
            return .save(replacing: existing)
        case .autoRename:
            return .save(replacing: nil)
        }
    }

    /// Deletes the asset an `overwrite` replaces, after the new asset was saved.
    ///
    /// Best effort: iOS asks the user to confirm the deletion, and if they decline
    /// (or it fails) both assets are kept. The save itself has already succeeded,
    /// so this never reports an error.
    static func deleteReplacedAsset(_ outcome: PhotosConflictOutcome) {
        guard case .save(let replacing?) = outcome else { return }
        try? PhotosConflictResolver.deleteAsset(replacing)
    }
}
#endif
