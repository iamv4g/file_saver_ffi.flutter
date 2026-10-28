import Foundation

/// Where a save writes its content, as decided by `FileManagerConflictResolver`.
///
/// Resolving never modifies anything on disk. Write the content to `writeURL`,
/// then call `commit()` once the write succeeded, or `discard()` after it failed
/// or was cancelled. `discard()` only removes the new file, never the file being
/// replaced, so a failed `overwrite` keeps the original.
enum FileSaveTarget {
    /// No conflict, or `autoRename`: the new file is written at this URL.
    case create(URL)

    /// `overwrite`: the content is written to `tempURL` in the same directory, and
    /// `commit()` replaces `finalURL` with it.
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
    /// Resolves the conflict for `fileName` in `directory` without modifying
    /// anything on disk.
    ///
    /// - Throws: `FileSaverError.fileExists` if the file exists and
    ///   `conflictResolution` is `.fail`.
    static func resolveConflict(
        directory: URL,
        fileName: String,
        conflictResolution: ConflictResolution
    ) throws -> FileSaveTarget {
        let targetURL = directory.appendingPathComponent(fileName)

        if !FileManager.default.fileExists(atPath: targetURL.path) {
            return .create(targetURL)
        }

        switch conflictResolution {
        case .autoRename:
            return .create(try autoRename(directory: directory, fileName: fileName))

        case .overwrite:
            let tempURL = directory.appendingPathComponent(".\(fileName).\(UUID().uuidString).tmp")
            return .replace(finalURL: targetURL, tempURL: tempURL)

        case .fail:
            throw FileSaverError.fileExists(fileName)

        case .skip:
            return .existing(targetURL)
        }
    }

    private static func autoRename(directory: URL, fileName: String) throws -> URL {
        let (name, ext) = splitFileName(fileName)

        for i in 1...Constants.maxRenameAttempts {
            let newName = "\(name) (\(i)).\(ext)"
            let newURL = directory.appendingPathComponent(newName)

            if !FileManager.default.fileExists(atPath: newURL.path) {
                return newURL
            }
        }

        throw FileSaverError.fileIO(
            "Failed to find available filename after \(Constants.maxRenameAttempts) attempts"
        )
    }

    private static func splitFileName(_ fileName: String) -> (name: String, ext: String) {
        let components = fileName.split(separator: ".")
        if components.count > 1 {
            let ext = String(components.last!)
            let name = components.dropLast().joined(separator: ".")
            return (name, ext)
        }
        return (fileName, "")
    }
}
