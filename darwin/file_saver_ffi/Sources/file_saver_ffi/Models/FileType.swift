import Foundation

struct FileType {

    var ext: String {
        didSet {
            ext = ext.lowercased()
        }
    }

    var mimeType: String {
        didSet {
            mimeType = mimeType.lowercased()
        }
    }

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

    var isImage: Bool { category == .image }
    var isVideo: Bool { category == .video }
    var isAudio: Bool { category == .audio }
}

