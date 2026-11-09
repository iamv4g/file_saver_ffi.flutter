import Foundation

// SaveLocation itself is generated, in Contracts.g.swift: from the Dart
// IosSaveLocation on iOS (the Documents/ directory of the app container, and
// the Photos Library), and from MacosSaveLocation on macOS.

extension SaveLocation {
    #if os(iOS)
    /// The location Dart sent as `value`, or `.documents` for an unknown one.
    static func fromInt(_ value: Int) -> SaveLocation {
        return SaveLocation(rawValue: value) ?? .documents
    }
    #elseif os(macOS)
    /// The location Dart sent as `value`, or `.downloads` for an unknown one.
    static func fromInt(_ value: Int) -> SaveLocation {
        return SaveLocation(rawValue: value) ?? .downloads
    }

    /// Returns the URL for this save location.
    ///
    /// Uses FileManager to get the standard directory path. In sandbox mode with proper entitlements,
    /// macOS creates symlinks from container paths to real user directories.
    /// The returned URL resolves symlinks to provide the real path.
    var directoryURL: URL {
        let url: URL
        switch self {
        case .downloads:
            url = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask)[0]
        case .pictures:
            url = FileManager.default.urls(for: .picturesDirectory, in: .userDomainMask)[0]
        case .movies:
            url = FileManager.default.urls(for: .moviesDirectory, in: .userDomainMask)[0]
        case .music:
            url = FileManager.default.urls(for: .musicDirectory, in: .userDomainMask)[0]
        case .documents:
            url = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        }
        // Resolve symlinks so the returned path is the real directory
        // (e.g., ~/Pictures instead of ~/Library/Containers/<id>/Data/Pictures)
        return url.resolvingSymlinksInPath()
    }
    #endif
}
