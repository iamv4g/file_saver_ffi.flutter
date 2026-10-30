import Foundation

/// Where a save writes its content, as decided by `FileManagerConflictResolver`.
///
/// Resolving creates the new file empty, so two saves can never pick the same
/// name, and never touches an existing file. Write the content to `writeURL`,
/// then call `commit()` once the write succeeded, or `discard()` if the save
/// fails or is cancelled at any later point. `discard()` only removes the new
/// file, never the file being replaced, so a failed `overwrite` keeps the
/// original.
enum FileSaveTarget {
    /// No conflict, or `autoRename`: the new file, created empty.
    case create(URL)

    /// `overwrite`: the content is written to `tempURL` (created empty) in the
    /// same directory, and `commit()` replaces `finalURL` with it.
    case replace(finalURL: URL, tempURL: URL)

    /// `skip`: the file already exists. Nothing is written and the save reports
    /// this URL.
    case existing(URL)

    /// File the new content is written to. For `.existing` this is the existing
    /// file, which must not be written.
    var writeURL: URL {
        switch self {
        case .create(let url), .existing(let url):
            return url
        case .replace(_, let tempURL):
            return tempURL
        }
    }

    /// Makes the written file the saved file and returns its final URL.
    ///
    /// On failure the new file is removed and the replaced file is left intact.
    func commit() throws -> URL {
        switch self {
        case .create(let url), .existing(let url):
            return url
        case .replace(let finalURL, let tempURL):
            do {
                if FileManager.default.fileExists(atPath: finalURL.path) {
                    let result = try FileManager.default.replaceItemAt(finalURL, withItemAt: tempURL)
                    return result ?? finalURL
                }
                // The original disappeared while we were writing: just move into place.
                try FileManager.default.moveItem(at: tempURL, to: finalURL)
                return finalURL
            } catch {
                discard()
                throw FileSaverError.fileIO("Failed to replace \(finalURL.lastPathComponent): \(error.localizedDescription)")
            }
        }
    }

    /// Removes the partially written new file. Never touches an existing file.
    func discard() {
        switch self {
        case .create(let url):
            try? FileManager.default.removeItem(at: url)
        case .replace(_, let tempURL):
            try? FileManager.default.removeItem(at: tempURL)
        case .existing:
            break
        }
    }
}

enum FileManagerConflictResolver {
    /// Resolves the conflict for `fileName` in `directory`. The file to write is
    /// created empty: existence is checked and the name claimed in one step
    /// (`O_CREAT | O_EXCL`).
    ///
    /// - Throws: `FileSaverError.fileExists` if the file exists and
    ///   `conflictResolution` is `.fail`, and the error of creating the file,
    ///   such as `permissionDenied` in a directory the app can't write.
    static func resolveConflict(
        directory: URL,
        fileName: String,
        conflictResolution: ConflictResolution
    ) throws -> FileSaveTarget {
        let targetURL = directory.appendingPathComponent(fileName)

        if try claim(targetURL) {
            return .create(targetURL)
        }

        switch conflictResolution {
        case .autoRename:
            return .create(try autoRename(directory: directory, fileName: fileName))

        case .overwrite:
            let tempURL = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
            try FileHelper.createFileExclusively(at: tempURL)
            return .replace(finalURL: targetURL, tempURL: tempURL)

        case .fail:
            throw FileSaverError.fileExists(fileName)

        case .skip:
            return .existing(targetURL)
        }
    }

    /// Creates `url` empty. Returns `false` if it already exists.
    private static func claim(_ url: URL) throws -> Bool {
        do {
            try FileHelper.createFileExclusively(at: url)
            return true
        } catch FileSaverError.fileExists {
            return false
        }
    }

    private static func autoRename(directory: URL, fileName: String) throws -> URL {
        for i in 1...Constants.maxRenameAttempts {
            let newURL = directory.appendingPathComponent(renamed(fileName, i))
            if try claim(newURL) {
                return newURL
            }
        }

        throw FileSaverError.fileIO(
            "Failed to find available filename after \(Constants.maxRenameAttempts) attempts"
        )
    }

    /// `photo.jpg` → `photo (n).jpg`. A name without an extension, or a dot
    /// file such as `.env`, gets the number at the end: `notes (n)`,
    /// `.env (n)`.
    static func renamed(_ fileName: String, _ n: Int) -> String {
        guard let dot = fileName.lastIndex(of: "."), dot != fileName.startIndex else {
            return "\(fileName) (\(n))"
        }
        return "\(fileName[..<dot]) (\(n))\(fileName[dot...])"
    }
}
