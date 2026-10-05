#if os(iOS)
import Foundation
import Photos

enum PhotosConflictResolver {
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

    static func overwriteAsset(_ asset: PHAsset) throws {
        try PHPhotoLibrary.shared().performChangesAndWait {
            PHAssetChangeRequest.deleteAssets([asset] as NSArray)
        }
    }
}
#endif
