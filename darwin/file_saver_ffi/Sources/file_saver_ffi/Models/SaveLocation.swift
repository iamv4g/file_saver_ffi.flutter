import Foundation

/// Represents save locations for files.
///
/// Platform-specific:
/// - iOS: Photos Library and Documents directory
/// - macOS: Downloads, Pictures, Movies, Music, and Documents directories
enum SaveLocation: Int {
    #if os(iOS)
    /// Documents/ directory in app container (default)
    case documents = 0

    /// Photos Library (requires Photos permission)
    case photos = 1

    /// Converts an integer index to SaveLocation enum.
    static func fromInt(_ value: Int) -> SaveLocation {
        return SaveLocation(rawValue: value) ?? .documents
    }
    #elseif os(macOS)
    /// ~/Downloads directory
    /// Sandbox: requires com.apple.security.files.downloads.read-write
    case downloads = 0

    /// ~/Pictures directory
    /// Sandbox: requires com.apple.security.assets.pictures.read-write
    case pictures = 1

    /// ~/Movies directory
    /// Sandbox: requires com.apple.security.assets.movies.read-write
    case movies = 2

    /// ~/Music directory
    /// Sandbox: requires com.apple.security.assets.music.read-write
    case music = 3

    /// App Container Documents directory (no entitlement needed)
    case documents = 4

    /// Converts an integer index to SaveLocation enum.
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
