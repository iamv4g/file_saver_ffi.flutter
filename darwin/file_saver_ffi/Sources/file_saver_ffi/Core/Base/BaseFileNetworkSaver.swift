import Foundation

// MARK: - Shared saveNetwork Implementation

extension BaseFileSaver {
    func saveNetworkImpl(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        fileType: FileType,
        baseFileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    ) {
        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        #if os(iOS)
        do {
            try checkPhotosSupport(saveLocation: saveLocation, fileType: fileType)
        } catch let error as FileSaverError {
            onError(error.code, error.message)
            onComplete()
            return
        } catch {
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
            return
        }

        switch saveLocation {
        case .documents:
            saveNetworkToDocumentsImpl(
                urlString: urlString,
                headers: headers,
                timeoutSeconds: timeoutSeconds,
                fileName: fileName,
                saveLocation: saveLocation,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: onProgress,
                onSuccess: onSuccess,
                onError: onError,
                onCancelled: onCancelled,
                onCancelHandlerReady: onCancelHandlerReady,
                onComplete: onComplete,
                cancellationToken: cancellationToken
            )

        case .photos:
            saveNetworkToPhotosImpl(
                urlString: urlString,
                headers: headers,
                timeoutSeconds: timeoutSeconds,
                fileName: fileName,
                fileType: fileType,
                baseFileName: baseFileName,
                subDir: subDir,
                conflictResolution: conflictResolution,
                onProgress: onProgress,
                onSuccess: onSuccess,
                onError: onError,
                onCancelled: onCancelled,
                onCancelHandlerReady: onCancelHandlerReady,
                onComplete: onComplete,
                cancellationToken: cancellationToken
            )
        }
        #elseif os(macOS)
        saveNetworkToDocumentsImpl(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            fileName: fileName,
            saveLocation: saveLocation,
            subDir: subDir,
            conflictResolution: conflictResolution,
            onProgress: onProgress,
            onSuccess: onSuccess,
            onError: onError,
            onCancelled: onCancelled,
            onCancelHandlerReady: onCancelHandlerReady,
            onComplete: onComplete,
            cancellationToken: cancellationToken
        )
        #endif
    }

    private func saveNetworkToDocumentsImpl(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        fileName: String,
        saveLocation: SaveLocation,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    ) {
        let target: FileSaveTarget
        do {
            let targetDir = try resolveTargetDirectory(saveLocation: saveLocation, subDir: subDir)
            target = try FileManagerConflictResolver.resolveConflict(
                directory: targetDir,
                fileName: fileName,
                conflictResolution: conflictResolution
            )
        } catch let error as FileSaverError {
            onError(error.code, error.message)
            onComplete()
            return
        } catch {
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
            return
        }

        if case .existing(let existingURL) = target {
            onProgress?(1.0)
            onSuccess(existingURL.absoluteString)
            onComplete()
            return
        }

        if let token = cancellationToken, token.isCancelled {
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
                defer { onComplete() }

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

    #if os(iOS)
    private func saveNetworkToPhotosImpl(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        fileName: String,
        fileType: FileType,
        baseFileName: String,
        subDir: String?,
        conflictResolution: ConflictResolution,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    ) {
        if let token = cancellationToken, token.isCancelled {
            onCancelled()
            onComplete()
            return
        }

        // Check permission + conflict BEFORE downloading
        let hasReadAccess: Bool
        let outcome: PhotosConflictOutcome
        do {
            let result = try handlePhotosSetup(
                fileName: fileName,
                subDir: subDir,
                conflictResolution: conflictResolution
            )
            hasReadAccess = result.hasReadAccess
            outcome = result.outcome

            if case .existing(let existingUri) = outcome {
                onProgress?(1.0)
                onSuccess(existingUri)
                onComplete()
                return
            }
        } catch let error as FileSaverError {
            onError(error.code, error.message)
            onComplete()
            return
        } catch {
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
            return
        }

        if let token = cancellationToken, token.isCancelled {
            onCancelled()
            onComplete()
            return
        }

        // Download after permission granted
        let downloadProgressHandler = progressMapper(from: onProgress, startProgress: 0.0, endProgress: 0.8)

        NetworkHelper.downloadToTempFile(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            fileName: fileName,
            onProgress: { [weak cancellationToken] downloadProgress in
                if let token = cancellationToken, token.isCancelled { return }
                downloadProgressHandler?(downloadProgress)
            },
            cancellationToken: cancellationToken,
            onCancelHandlerReady: onCancelHandlerReady,
            completion: { result in
                switch result {
                case .success(let (tmpURL, _)):
                    if let token = cancellationToken, token.isCancelled {
                        try? FileManager.default.removeItem(at: tmpURL)
                        onCancelled()
                        onComplete()
                        return
                    }

                    self.saveDownloadedFileToPhotosImpl(
                        tmpURL: tmpURL,
                        hasReadAccess: hasReadAccess,
                        outcome: outcome,
                        fileType: fileType,
                        baseFileName: baseFileName,
                        subDir: subDir,
                        onProgress: onProgress,
                        onSuccess: onSuccess,
                        onError: onError,
                        onCancelled: onCancelled,
                        onComplete: onComplete,
                        cancellationToken: cancellationToken
                    )

                case .failure(let error):
                    if case .cancelled = error {
                        onCancelled()
                    } else {
                        onError(error.code, error.message)
                    }
                    onComplete()
                }
            }
        )
    }

    private func saveDownloadedFileToPhotosImpl(
        tmpURL: URL,
        hasReadAccess: Bool,
        outcome: PhotosConflictOutcome,
        fileType: FileType,
        baseFileName: String,
        subDir: String?,
        onProgress: ((Double) -> Void)?,
        onSuccess: @escaping (String) -> Void,
        onError: @escaping (String, String) -> Void,
        onCancelled: @escaping () -> Void,
        onComplete: @escaping () -> Void,
        cancellationToken: CancellationToken?
    ) {
        func cleanup() {
            try? FileManager.default.removeItem(at: tmpURL)
        }

        if let token = cancellationToken, token.isCancelled {
            cleanup()
            onCancelled()
            onComplete()
            return
        }

        onProgress?(0.8)

        let fileName = buildFileName(base: baseFileName, extension: fileType.ext)

        do {
            let uri = try saveFileToPhotos(
                sourceURL: tmpURL,
                fileName: fileName,
                albumName: hasReadAccess ? subDir : nil,
                onProgress: progressMapper(from: onProgress, startProgress: 0.8, endProgress: 1.0)
            )

            cleanup()
            PhotosHelper.deleteReplacedAsset(outcome)
            onProgress?(1.0)
            onSuccess(uri)
            onComplete()
        } catch FileSaverError.cancelled {
            cleanup()
            onCancelled()
            onComplete()
        } catch let error as FileSaverError {
            cleanup()
            onError(error.code, error.message)
            onComplete()
        } catch {
            cleanup()
            onError(Constants.errorPlatform, error.localizedDescription)
            onComplete()
        }
    }
    #endif
}
