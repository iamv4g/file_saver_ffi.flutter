import Foundation

// MARK: - Save*As Implementation (User-Selected Directory)

extension BaseFileSaver {
    /// Save bytes to user-selected directory
    func saveBytesAs(
        fileData: Data,
        directoryURL: URL,
        fileName: String,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        try validateFileData(fileData)

        // Start security-scoped access
        guard directoryURL.startAccessingSecurityScopedResource() else {
            throw FileSaverError.permissionDenied("Cannot access selected directory")
        }
        defer { directoryURL.stopAccessingSecurityScopedResource() }

        // Resolve conflict
        let target = try FileManagerConflictResolver.resolveConflict(
            directory: directoryURL,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        if case .existing(let existingURL) = target {
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            return
        }

        // Write with progress
        do {
            try FileHelper.writeFileWithProgress(
                data: fileData,
                to: target.writeURL,
                onProgress: onProgress,
                cancellationToken: cancellationToken
            )
        } catch {
            target.discard()
            throw error
        }

        // Commit inside the security scope: replacing a file needs access to it.
        onSuccess(try target.commit().absoluteString)
    }

    /// Save file to user-selected directory
    func saveFileAs(
        filePath: String,
        directoryURL: URL,
        fileName: String,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: (String) -> Void,
        cancellationToken: CancellationToken?
    ) throws {
        // Start security-scoped access
        guard directoryURL.startAccessingSecurityScopedResource() else {
            throw FileSaverError.permissionDenied("Cannot access selected directory")
        }
        defer { directoryURL.stopAccessingSecurityScopedResource() }

        // Resolve conflict before opening the source so a skip never reads it
        let target = try FileManagerConflictResolver.resolveConflict(
            directory: directoryURL,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        if case .existing(let existingURL) = target {
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            return
        }

        let downloadProgressHandler = progressMapper(from: onProgress, startProgress: 0.0, endProgress: 0.8)

        let sourceFile = try FileHelper.openSourceFile(
            at: filePath,
            onDownloadProgress: downloadProgressHandler
        )
        defer { sourceFile.close() }

        let copyProgressHandler = progressMapper(from: onProgress, startProgress: 0.8, endProgress: 1.0)

        do {
            try FileHelper.copyFileWithProgress(
                from: sourceFile.handle,
                to: target.writeURL,
                totalSize: sourceFile.totalSize,
                onProgress: copyProgressHandler,
                cancellationToken: cancellationToken
            )
        } catch {
            target.discard()
            throw error
        }

        onSuccess(try target.commit().absoluteString)
    }

    /// Save network file to user-selected directory
    func saveNetworkAs(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        directoryURL: URL,
        fileName: String,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    ) {
        // Start security-scoped access
        guard directoryURL.startAccessingSecurityScopedResource() else {
            onError(Constants.errorPermissionDenied, "Cannot access selected directory")
            onComplete()
            return
        }

        // Resolve conflict first
        let target: FileSaveTarget
        do {
            target = try FileManagerConflictResolver.resolveConflict(
                directory: directoryURL,
                fileName: fileName,
                conflictResolution: conflictResolution
            )
        } catch let error as FileSaverError {
            directoryURL.stopAccessingSecurityScopedResource()
            onError(error.code, error.message)
            onComplete()
            return
        } catch {
            directoryURL.stopAccessingSecurityScopedResource()
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
            return
        }

        if case .existing(let existingURL) = target {
            directoryURL.stopAccessingSecurityScopedResource()
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            onComplete()
            return
        }

        if let token = cancellationToken, token.isCancelled {
            directoryURL.stopAccessingSecurityScopedResource()
            onCancelled()
            onComplete()
            return
        }

        // Download to the new file (a temp file for overwrite); commit on success
        NetworkHelper.downloadToFile(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            destinationURL: target.writeURL,
            onProgress: { [weak cancellationToken] progress in
                if let token = cancellationToken, token.isCancelled { return }
                onProgress?(progress)
            },
            cancellationToken: cancellationToken,
            onCancelHandlerReady: onCancelHandlerReady,
            completion: { result in
                defer {
                    directoryURL.stopAccessingSecurityScopedResource()
                    onComplete()
                }

                switch result {
                case .success:
                    if let token = cancellationToken, token.isCancelled {
                        target.discard()
                        onCancelled()
                        return
                    }
                    do {
                        onSuccess(try target.commit().absoluteString)
                    } catch let error as FileSaverError {
                        onError(error.code, error.message)
                    } catch {
                        onError(Constants.errorFileIO, error.localizedDescription)
                    }
                case .failure(let error):
                    target.discard()
                    if case .cancelled = error {
                        onCancelled()
                    } else {
                        onError(error.code, error.message)
                    }
                }
            }
        )
    }
}
