import Foundation

struct FileType {
    let ext: String
    let mimeType: String

    init(ext: String, mimeType: String) {
        self.ext = ext.lowercased()
        self.mimeType = mimeType.lowercased()
    }

    enum Category {
        case image
        case video
        case audio
        case custom
    }

    var category: Category {
        if mimeType.hasPrefix("image/") {
            return .image
        } else if mimeType.hasPrefix("video/") {
            return .video
        } else if mimeType.hasPrefix("audio/") {
            return .audio
        } else {
            return .custom
        }
    }
}

