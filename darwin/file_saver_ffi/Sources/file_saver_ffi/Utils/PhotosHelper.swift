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
        if #available(iOS 14, *) {
            let readWrite = authorize(.readWrite, request: needAlbum)
            if readWrite == .authorized || readWrite == .limited {
                return true
            }
            guard !needAlbum, authorize(.addOnly, request: true) == .authorized else {
                throw FileSaverError.permissionDenied("Photo library access denied")
            }
            return false
        } else {
            var status = PHPhotoLibrary.authorizationStatus()
            if status == .notDetermined {
                status = waitForAuthorization { PHPhotoLibrary.requestAuthorization($0) }
            }
            guard status == .authorized else {
                throw FileSaverError.permissionDenied("Photo library access denied")
            }
            return true
        }
    }

    /// Returns the status of `accessLevel`, first asking the user if it is
    /// undetermined and `request` is `true`.
    @available(iOS 14, *)
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
