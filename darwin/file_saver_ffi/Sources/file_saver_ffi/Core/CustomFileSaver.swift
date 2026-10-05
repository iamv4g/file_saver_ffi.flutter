import Foundation

class CustomFileSaver: BaseFileSaver {
    // MARK: - Hooks
    
    // Uses all defaults:
    // - supportsPhotosLibrary = false (Documents only)
    // - validateFormat = no-op (accepts any file type)
    
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
