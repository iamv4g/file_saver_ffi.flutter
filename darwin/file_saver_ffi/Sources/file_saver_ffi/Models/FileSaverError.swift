import Foundation

enum FileSaverError: Error {
    case permissionDenied(String)
    case fileExists(String)
    case writeSessionSkipped
    case invalidInput(String)
    case unsupportedFormat(String, details: String? = nil)
    case storageFull(String)
    case fileIO(String)
    case fileNotFound(String)
    case iCloudDownloadFailed(String)
    case networkError(String, statusCode: Int? = nil)
    case platformError(String)
    case cancelled

    #if os(iOS)
    /// A file type that can't be saved to the Photos Library.
    static func photosUnsupported(_ fileType: FileType) -> FileSaverError {
        .invalidInput(
            "\(fileType.mimeType) (.\(fileType.ext)) can't be saved to the Photos Library, "
                + "which only takes images and videos. Save it to IosSaveLocation.documents instead."
        )
    }
    #endif
    
    var code: String {
        switch self {
        case .permissionDenied: return ErrorCode.permissionDenied
        case .fileExists: return ErrorCode.fileExists
        case .writeSessionSkipped: return ErrorCode.fileExists
        case .invalidInput: return ErrorCode.invalidInput
        case .unsupportedFormat: return ErrorCode.unsupportedFormat
        case .storageFull: return ErrorCode.storageFull
        case .fileIO: return ErrorCode.fileIO
        case .fileNotFound: return ErrorCode.fileNotFound
        case .iCloudDownloadFailed: return ErrorCode.iCloudDownloadFailed
        case .networkError: return ErrorCode.network
        case .platformError: return ErrorCode.platform
        case .cancelled: return ErrorCode.cancelled
        }
    }
    
    /// The HTTP status of a network error.
    var statusCode: Int? {
        if case .networkError(_, let statusCode) = self { return statusCode }
        return nil
    }

    /// The detail the Dart exception for `code` needs (see
    /// `FileSaverErrorCode` in Dart): just the file name, path or reason,
    /// without a prefix that Dart adds again.
    var message: String {
        switch self {
        case .permissionDenied(let msg): return msg
        case .fileExists(let fileName): return fileName
        case .writeSessionSkipped: return "Write session skipped: the file already exists"
        case .invalidInput(let reason): return reason
        case .unsupportedFormat(let format, _): return format
        case .storageFull(let msg): return msg
        case .fileIO(let msg): return msg
        case .fileNotFound(let path): return path
        case .iCloudDownloadFailed(let msg): return msg
        case .networkError(let msg, _): return msg
        case .platformError(let msg): return msg
        case .cancelled: return "Operation was cancelled"
        }
    }
}
