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
        let finalURL = try FileManagerConflictResolver.resolveConflict(
            directory: directoryURL,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        // Write with progress
        do {
            try FileHelper.writeFileWithProgress(
                data: fileData,
                to: finalURL,
                onProgress: onProgress,
                cancellationToken: cancellationToken
            )
        } catch FileSaverError.cancelled {
            try? FileManager.default.removeItem(at: finalURL)
            throw FileSaverError.cancelled
        }

        onSuccess(finalURL.absoluteString)
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

        let downloadProgressHandler = progressMapper(from: onProgress, startProgress: 0.0, endProgress: 0.8)

        let sourceFile = try FileHelper.openSourceFile(
            at: filePath,
            onDownloadProgress: downloadProgressHandler
        )
        defer { sourceFile.close() }

        // Resolve conflict
        let finalURL = try FileManagerConflictResolver.resolveConflict(
            directory: directoryURL,
            fileName: fileName,
            conflictResolution: conflictResolution
        )

        let copyProgressHandler = progressMapper(from: onProgress, startProgress: 0.8, endProgress: 1.0)

        do {
            try FileHelper.copyFileWithProgress(
                from: sourceFile.handle,
                to: finalURL,
                totalSize: sourceFile.totalSize,
                onProgress: copyProgressHandler,
                cancellationToken: cancellationToken
            )
        } catch FileSaverError.cancelled {
            try? FileManager.default.removeItem(at: finalURL)
            throw FileSaverError.cancelled
        }

        onSuccess(finalURL.absoluteString)
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
        let finalURL: URL
        do {
            finalURL = try FileManagerConflictResolver.resolveConflict(
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

        if let token = cancellationToken, token.isCancelled {
            directoryURL.stopAccessingSecurityScopedResource()
            onCancelled()
            onComplete()
            return
        }

        // Download directly to final URL
        NetworkHelper.downloadToFile(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            destinationURL: finalURL,
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
                        try? FileManager.default.removeItem(at: finalURL)
                        onCancelled()
                        return
                    }
                    onSuccess(finalURL.absoluteString)
                case .failure(let error):
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
