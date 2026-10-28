#if os(iOS)
import Foundation
import Photos

/// Result of resolving a Photos Library name conflict.
enum PhotosConflictOutcome {
    /// Save a new asset. `replacing` (overwrite only) is deleted after the new
    /// asset has been saved.
    case save(replacing: PHAsset?)

    /// `skip`: the asset exists, so nothing is saved and the save reports `uri`.
    case existing(uri: String)
}

enum PhotosConflictResolver {
    /// Finds an asset with `fileName` as its original file name, in `albumName`
    /// when given, otherwise anywhere in the library.
    static func findExistingAsset(fileName: String, inAlbum albumName: String?) -> PHAsset? {
        let options = PHFetchOptions()

        var collection: PHAssetCollection?
        if let albumName = albumName {
            let collectionOptions = PHFetchOptions()
            collectionOptions.predicate = NSPredicate(format: "title = %@", albumName)
            collection = PHAssetCollection.fetchAssetCollections(
                with: .album,
                subtype: .any,
                options: collectionOptions
            ).firstObject

            // The album doesn't exist yet, so it can't contain the asset. Don't
            // fall back to searching (and possibly overwriting) the whole library.
            if collection == nil {
                return nil
            }
        }

        let assets = collection != nil
            ? PHAsset.fetchAssets(in: collection!, options: options)
            : PHAsset.fetchAssets(with: options)

        for i in 0..<assets.count {
            let asset = assets.object(at: i)
            if let resources = PHAssetResource.assetResources(for: asset).first,
               resources.originalFilename == fileName {
                return asset
            }
        }

        return nil
    }

    static func deleteAsset(_ asset: PHAsset) throws {
        try PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }
}
#endif
