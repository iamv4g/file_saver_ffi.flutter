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
    
    var code: String {
        switch self {
        case .permissionDenied: return Constants.errorPermissionDenied
        case .fileExists: return Constants.errorFileExists
        case .writeSessionSkipped: return Constants.errorFileExists
        case .invalidInput: return Constants.errorInvalidInput
        case .unsupportedFormat: return Constants.errorUnsupportedFormat
        case .storageFull: return Constants.errorStorageFull
        case .fileIO: return Constants.errorFileIO
        case .fileNotFound: return Constants.errorFileNotFound
        case .iCloudDownloadFailed: return Constants.errorICloudDownloadFailed
        case .networkError: return Constants.errorNetwork
        case .platformError: return Constants.errorPlatform
        case .cancelled: return Constants.errorCancelled
        }
    }
    
    var message: String {
        switch self {
        case .permissionDenied(let msg): return msg
        case .fileExists(let fileName): return "File already exists: \(fileName)"
        case .writeSessionSkipped: return "Write session skipped: file already exists"
        case .invalidInput(let reason): return "Invalid input: \(reason)"
        case .unsupportedFormat(let format, let details):
            if let details = details {
                return "Unsupported format: \(format) - \(details)"
            }
            return "Unsupported format: \(format)"
        case .storageFull(let msg): return msg
        case .fileIO(let msg): return msg
        case .fileNotFound(let path): return "Source file not found: \(path)"
        case .iCloudDownloadFailed(let msg): return "iCloud download failed: \(msg)"
        case .networkError(let msg, let statusCode):
            if let statusCode = statusCode {
                return "Network download failed (HTTP \(statusCode)): \(msg)"
            }
            return "Network download failed: \(msg)"
        case .platformError(let msg): return msg
        case .cancelled: return "Operation was cancelled"
        }
    }
}
