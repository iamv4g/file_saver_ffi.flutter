import Foundation

enum FileManagerConflictResolver {
    static func resolveConflict(
        directory: URL,
        fileName: String,
        conflictResolution: ConflictResolution
    ) throws -> URL {
        let targetURL = directory.appendingPathComponent(fileName)
        let fileExists = FileManager.default.fileExists(atPath: targetURL.path)

        if !fileExists {
            return targetURL
        }

        switch conflictResolution {
        case .autoRename:
            return try autoRename(directory: directory, fileName: fileName)

        case .overwrite:
            if fileExists {
                try FileManager.default.removeItem(at: targetURL)
            }
            return targetURL

        case .fail:
            if fileExists {
                throw FileSaverError.fileExists(fileName)
            }
            return targetURL

        case .skip:
            return targetURL
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
