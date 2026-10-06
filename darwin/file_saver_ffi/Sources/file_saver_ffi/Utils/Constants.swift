import Foundation

enum Constants {
    static let errorInvalidInput = "INVALID_INPUT"
    static let errorPermissionDenied = "PERMISSION_DENIED"
    static let errorUnsupportedFormat = "UNSUPPORTED_FORMAT"
    static let errorStorageFull = "STORAGE_FULL"
    static let errorFileExists = "FILE_EXISTS"
    static let errorFileIO = "FILE_IO_ERROR"
    static let errorFileNotFound = "FILE_NOT_FOUND"
    static let errorICloudDownloadFailed = "ICLOUD_DOWNLOAD_FAILED"
    static let errorNetwork = "NETWORK_ERROR"
    static let errorPlatform = "PLATFORM_ERROR"
    static let errorCancelled = "CANCELLED"
    
    static let chunkSize = 1024 * 1024
    static let maxRenameAttempts = 1000
    static let iCloudDownloadTimeout: TimeInterval = 60.0
}
