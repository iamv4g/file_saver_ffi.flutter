import Foundation

enum FileHelper {
    static func getFileType(ext: String, mimeType: String) -> FileType {
        let normalizedExt = ext.lowercased().replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        return FileType(ext: normalizedExt, mimeType: mimeType)
    }

    static func buildFileName(fileName: String, extension ext: String) -> String {
        let cleanExt = ext.replacingOccurrences(of: ".", with: "").trimmingCharacters(in: .whitespaces)
        return cleanExt.isEmpty ? fileName : "\(fileName).\(cleanExt)"
    }

    static func writeFile(data: Data, to url: URL) throws {
        try writeFileWithProgress(data: data, to: url, onProgress: nil, cancellationToken: nil)
    }

    /// Writes data to file with progress reporting and cancellation support
    ///
    /// - Parameters:
    ///   - data: Data to write
    ///   - url: File URL to write to
    ///   - onProgress: Optional progress callback (0.0 to 1.0)
    ///   - cancellationToken: Optional token to check for cancellation between chunks
    static func writeFileWithProgress(
        data: Data,
        to url: URL,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken? = nil
    ) throws {
        let fileHandle = try openForWriting(url)

        defer { try? fileHandle.close() }

        var offset = 0
        let chunkSize = Constants.chunkSize
        let totalBytes = data.count

        while offset < totalBytes {
            // Check for cancellation before each chunk
            try cancellationToken?.throwIfCancelled()

            let length = min(chunkSize, totalBytes - offset)
            let chunk = data.subdata(in: offset..<(offset + length))
            do {
                try fileHandle.write(contentsOf: chunk)
            } catch {
                throw ioError(error, url: url)
            }
            offset += length

            // Report progress
            if let onProgress = onProgress, totalBytes > 0 {
                let progress = Double(offset) / Double(totalBytes)
                onProgress(progress)
            }
        }
    }

    static func ensureDirectoryExists(at url: URL) throws {
        let fileManager = FileManager.default

        if fileManager.fileExists(atPath: url.path) {
            var isDirectory: ObjCBool = false
            fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory)

            if !isDirectory.boolValue {
                throw FileSaverError.fileIO("Path exists but is not a directory: \(url.path)")
            }
        } else {
            try fileManager.createDirectory(at: url, withIntermediateDirectories: true, attributes: nil)
        }
    }

    // MARK: - Creating and Writing Files

    /// Creates `url` as a new, empty file. Fails with `FileSaverError.fileExists`
    /// if it exists, so two saves can never claim the same name.
    static func createFileExclusively(at url: URL) throws {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_EXCL | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(errno, url: url) }
        close(fd)
    }

    /// Opens `url` for writing, creating it if needed and truncating it.
    static func openForWriting(_ url: URL) throws -> FileHandle {
        let fd = open(url.path, O_WRONLY | O_CREAT | O_TRUNC | O_CLOEXEC, 0o644)
        guard fd >= 0 else { throw posixError(errno, url: url) }
        return FileHandle(fileDescriptor: fd, closeOnDealloc: true)
    }

    /// Converts a failed write to `url` into a `FileSaverError`.
    static func ioError(_ error: Error, url: URL) -> FileSaverError {
        if let error = error as? FileSaverError { return error }
        let nsError = error as NSError
        if nsError.domain == NSPOSIXErrorDomain {
            return posixError(Int32(nsError.code), url: url)
        }
        if let underlying = nsError.userInfo[NSUnderlyingErrorKey] as? NSError,
           underlying.domain == NSPOSIXErrorDomain {
            return posixError(Int32(underlying.code), url: url)
        }
        switch nsError.code {
        case NSFileWriteOutOfSpaceError:
            return .storageFull("Not enough storage to write \(url.lastPathComponent)")
        case NSFileWriteNoPermissionError, NSFileWriteVolumeReadOnlyError:
            return .permissionDenied("No permission to write \(url.path)")
        default:
            return .fileIO("Failed to write \(url.path): \(error.localizedDescription)")
        }
    }

    /// Converts the `errno` of a failed call on `url` into a `FileSaverError`.
    static func posixError(_ code: Int32, url: URL) -> FileSaverError {
        let reason = String(cString: strerror(code))
        switch code {
        case EEXIST:
            return .fileExists(url.lastPathComponent)
        case EACCES, EPERM, EROFS:
            // EPERM is what the sandbox reports outside the app's access.
            return .permissionDenied("No permission to write \(url.path): \(reason)")
        case ENOSPC, EDQUOT:
            return .storageFull("Not enough storage to write \(url.lastPathComponent)")
        default:
            return .fileIO("Failed to write \(url.path): \(reason)")
        }
    }
    
    // MARK: - Source File Operations
    
    /// Result of opening a source file
    struct SourceFile {
        let url: URL
        let handle: FileHandle
        let totalSize: Int64
        let isSecurityScoped: Bool
        
        /// Closes the file handle and releases security scope if needed
        func close() {
            try? handle.close()
            if isSecurityScoped {
                url.stopAccessingSecurityScopedResource()
            }
        }
    }
    
    /// Opens a source file URL, handling security-scoped resources and iCloud downloads
    ///
    /// - Parameters:
    ///   - filePath: The file path or URL string
    ///   - onDownloadProgress: Optional callback for iCloud download progress (0.0 to 1.0)
    /// - Returns: SourceFile containing URL, FileHandle, totalSize, and security scope info
    /// - Throws: FileSaverError on failure
    static func openSourceFile(
        at filePath: String,
        onDownloadProgress: ((Double) -> Void)? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws -> SourceFile {
        // A plain path is taken as is: `#`, `?` and `%` are part of the name.
        let url = filePath.hasPrefix("file://")
            ? URL(string: filePath) ?? URL(fileURLWithPath: filePath)
            : URL(fileURLWithPath: filePath)
        
        // Try to access security-scoped resource (for Files app, iCloud, etc.)
        let isSecurityScoped = url.startAccessingSecurityScopedResource()
        
        do {
            // Check if file exists
            guard FileManager.default.fileExists(atPath: url.path) else {
                if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
                throw FileSaverError.fileNotFound(filePath)
            }
            
            // Handle iCloud files that may need to be downloaded (with progress)
            try waitForICloudDownload(
                at: url,
                onProgress: onDownloadProgress,
                cancellationToken: cancellationToken
            )
            
            // Get file size
            let attributes = try FileManager.default.attributesOfItem(atPath: url.path)
            let totalSize = (attributes[.size] as? Int64) ?? 0
            
            // Open file handle for reading
            let handle = try FileHandle(forReadingFrom: url)
            
            return SourceFile(
                url: url,
                handle: handle,
                totalSize: totalSize,
                isSecurityScoped: isSecurityScoped
            )
        } catch let error as FileSaverError {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            throw error
        } catch {
            if isSecurityScoped { url.stopAccessingSecurityScopedResource() }
            throw FileSaverError.fileIO("Failed to open source file: \(error.localizedDescription)")
        }
    }
    
    /// Waits for an iCloud file to finish downloading with progress reporting
    ///
    /// Uses polling to monitor download progress and NSFileCoordinator to ensure completion
    ///
    /// - Parameters:
    ///   - url: The URL of the file to check
    ///   - timeout: Maximum time to wait for download (default 60 seconds)
    ///   - onProgress: Optional progress callback, called with 0.0 when the
    ///     download starts and 1.0 when it is done. iOS doesn't report the
    ///     progress in between.
    ///   - cancellationToken: Checked between polls.
    /// - Throws: FileSaverError.iCloudDownloadFailed on timeout or failure,
    ///   FileSaverError.cancelled when cancelled
    static func waitForICloudDownload(
        at url: URL,
        timeout: TimeInterval = Constants.iCloudDownloadTimeout,
        onProgress: ((Double) -> Void)? = nil,
        cancellationToken: CancellationToken? = nil
    ) throws {
        // Check if file is in iCloud
        var isUbiquitous = false
        var downloadStatus: URLUbiquitousItemDownloadingStatus?
        
        if let values = try? url.resourceValues(forKeys: [
            .isUbiquitousItemKey,
            .ubiquitousItemDownloadingStatusKey,
        ]) {
            isUbiquitous = values.isUbiquitousItem ?? false
            downloadStatus = values.ubiquitousItemDownloadingStatus
        }
        
        // Not an iCloud file, return immediately
        guard isUbiquitous else {
            onProgress?(1.0)
            return
        }
        
        // Already downloaded
        if downloadStatus == .current {
            onProgress?(1.0)
            return
        }
        
        // Not downloaded, or only an older version (`.downloaded`)
        try FileManager.default.startDownloadingUbiquitousItem(at: url)
        
        // Report initial progress
        onProgress?(0.0)
        
        // Poll for download progress
        let startTime = Date()
        let pollInterval: TimeInterval = 0.2  // Poll every 200ms
        
        while true {
            try cancellationToken?.throwIfCancelled()

            // Check timeout
            let elapsed = Date().timeIntervalSince(startTime)
            if elapsed >= timeout {
                throw FileSaverError.iCloudDownloadFailed(
                    "Download timed out after \(Int(timeout)) seconds")
            }
            
            // Get current download status and progress
            if let values = try? url.resourceValues(forKeys: [
                .ubiquitousItemDownloadingStatusKey,
                .ubiquitousItemDownloadingErrorKey,
            ]) {
                // Check for download error
                if let error = values.ubiquitousItemDownloadingError {
                    throw FileSaverError.iCloudDownloadFailed(error.localizedDescription)
                }
                
                // Check if download is complete
                if values.ubiquitousItemDownloadingStatus == .current {
                    onProgress?(1.0)
                    break
                }
            }
            
            // Wait before next poll
            Thread.sleep(forTimeInterval: pollInterval)
        }
        
        // Use NSFileCoordinator to ensure file is fully available
        var coordinatorError: NSError?
        let semaphore = DispatchSemaphore(value: 0)
        var coordinationSuccess = false
        
        let coordinator = NSFileCoordinator(filePresenter: nil)
        
        DispatchQueue.global(qos: .userInitiated).async {
            coordinator.coordinate(
                readingItemAt: url,
                options: .withoutChanges,
                error: &coordinatorError
            ) { _ in
                coordinationSuccess = true
                semaphore.signal()
            }
            
            if coordinatorError != nil {
                semaphore.signal()
            }
        }
        
        // Short timeout for coordination (file should already be downloaded)
        let coordTimeout: TimeInterval = 5.0
        let result = semaphore.wait(timeout: .now() + coordTimeout)
        
        if result == .timedOut {
            throw FileSaverError.iCloudDownloadFailed("File coordination timed out")
        }
        
        if let error = coordinatorError {
            throw FileSaverError.iCloudDownloadFailed(error.localizedDescription)
        }
        
        if !coordinationSuccess {
            throw FileSaverError.iCloudDownloadFailed("File coordination failed")
        }
    }
    
    /// Copies file from source to destination with progress reporting and cancellation support
    ///
    /// Reads and writes in chunks to avoid loading entire file into memory.
    ///
    /// - Parameters:
    ///   - source: Source file handle (for reading)
    ///   - destination: Destination URL to write to
    ///   - totalSize: Total size of source file in bytes
    ///   - onProgress: Progress callback (0.0 to 1.0)
    ///   - cancellationToken: Optional token to check for cancellation between chunks
    static func copyFileWithProgress(
        from source: FileHandle,
        to destination: URL,
        totalSize: Int64,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken? = nil
    ) throws {
        let destHandle = try openForWriting(destination)
        defer { try? destHandle.close() }

        var bytesWritten: Int64 = 0
        let chunkSize = Constants.chunkSize

        while true {
            // Check for cancellation before each chunk
            try cancellationToken?.throwIfCancelled()

            guard let data = try source.read(upToCount: chunkSize), !data.isEmpty else {
                break
            }

            do {
                try destHandle.write(contentsOf: data)
            } catch {
                throw ioError(error, url: destination)
            }
            bytesWritten += Int64(data.count)

            if let onProgress = onProgress, totalSize > 0 {
                let progress = Double(bytesWritten) / Double(totalSize)
                onProgress(min(progress, 1.0))
            }
        }
    }
}
