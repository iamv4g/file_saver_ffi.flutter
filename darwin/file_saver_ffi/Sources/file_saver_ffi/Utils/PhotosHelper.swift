#if os(iOS)
import Foundation
import Photos

class PhotosHelper {
    /// Requests photo library permission from the user.
    ///
    /// - Parameter needAlbum: If `true`, requests `.readWrite` for album & conflict resolution support.
    ///   If `false`, requests `.addOnly` for basic save without albums.
    /// - Returns: `true` if read/write access granted (full or limited), `false` if add-only.
    /// - Throws: `FileSaverError.permissionDenied` if the user denies access.
    static func requestPermission(needAlbum: Bool) throws -> Bool {
        if #available(iOS 14, *) {
            let accessLevel: PHAccessLevel = needAlbum ? .readWrite : .addOnly
            var status = PHPhotoLibrary.authorizationStatus(for: accessLevel)

            if status == .notDetermined {
                let semaphore = DispatchSemaphore(value: 0)

                PHPhotoLibrary.requestAuthorization(for: accessLevel) { authStatus in
                    status = authStatus
                    semaphore.signal()
                }

                semaphore.wait()
                Thread.sleep(forTimeInterval: 0.5)
            }

            if accessLevel == .readWrite {
                guard status == .authorized || status == .limited else {
                    throw FileSaverError.permissionDenied("Photo library access denied")
                }
                return true
            } else {
                guard status == .authorized else {
                    throw FileSaverError.permissionDenied("Photo library access denied")
                }
                return false
            }
        } else {
            var status = PHPhotoLibrary.authorizationStatus()

            if status == .notDetermined {
                let semaphore = DispatchSemaphore(value: 0)

                PHPhotoLibrary.requestAuthorization { authStatus in
                    status = authStatus
                    semaphore.signal()
                }

                semaphore.wait()
                Thread.sleep(forTimeInterval: 0.5)
            }

            guard status == .authorized else {
                throw FileSaverError.permissionDenied("Photo library access denied")
            }

            return true
        }
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
