import Foundation

/// Delegate class for URLSession download progress tracking.
private class DownloadDelegate: NSObject, URLSessionDownloadDelegate {
    let destinationURL: URL
    let onProgress: ((Double) -> Void)?
    let cancellationToken: CancellationToken?
    let completion: (Result<(URL, Int64), FileSaverError>) -> Void
    
    var httpStatusCode: Int?
    private var hasCompleted = false
    private let completionLock = NSLock()
    
    init(
        destinationURL: URL,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken?,
        completion: @escaping (Result<(URL, Int64), FileSaverError>) -> Void
    ) {
        self.destinationURL = destinationURL
        self.onProgress = onProgress
        self.cancellationToken = cancellationToken
        self.completion = completion
    }
    
    private func complete(with result: Result<(URL, Int64), FileSaverError>) {
        completionLock.lock()
        defer { completionLock.unlock() }
        
        guard !hasCompleted else { return }
        hasCompleted = true
        completion(result)
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didFinishDownloadingTo location: URL
    ) {
        if let token = cancellationToken, token.isCancelled {
            self.complete(with: .failure(.cancelled))
            return
        }

        if let httpResponse = downloadTask.response as? HTTPURLResponse {
            httpStatusCode = httpResponse.statusCode
        }

        if let statusCode = httpStatusCode, !(200...299).contains(statusCode) {
            complete(with: .failure(.networkError("Server returned error", statusCode: statusCode)))
            return
        }

        do {
            try? FileManager.default.removeItem(at: destinationURL)
            try FileManager.default.moveItem(at: location, to: destinationURL)

            let totalSize = downloadTask.countOfBytesReceived
            complete(with: .success((destinationURL, totalSize)))
        } catch {
            complete(with: .failure(.fileIO(error.localizedDescription)))
        }
    }
    
    func urlSession(
        _ session: URLSession,
        downloadTask: URLSessionDownloadTask,
        didWriteData bytesWritten: Int64,
        totalBytesWritten: Int64,
        totalBytesExpectedToWrite: Int64
    ) {
        if let token = cancellationToken, token.isCancelled {
            downloadTask.cancel()
            return
        }
        
        if let onProgress = onProgress, totalBytesExpectedToWrite > 0 {
            let progress = Double(totalBytesWritten) / Double(totalBytesExpectedToWrite)
            onProgress(min(progress, 1.0))
        }
    }
    
    func urlSession(
        _ session: URLSession,
        task: URLSessionTask,
        didCompleteWithError error: Error?
    ) {
        if httpStatusCode == nil, let httpResponse = task.response as? HTTPURLResponse {
            httpStatusCode = httpResponse.statusCode
        }
        
        guard let error = error else { return }
        
        try? FileManager.default.removeItem(at: destinationURL)
        
        let statusCode = httpStatusCode
        
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut:
                complete(with: .failure(.networkError("Request timed out", statusCode: statusCode)))
            case .cancelled:
                // Check if this was user-initiated cancellation
                if let token = cancellationToken, token.isCancelled {
                    complete(with: .failure(.cancelled))
                } else {
                    complete(with: .failure(.cancelled))
                }
            case .notConnectedToInternet:
                complete(with: .failure(.networkError("No internet connection", statusCode: statusCode)))
            default:
                complete(with: .failure(.networkError(urlError.localizedDescription, statusCode: statusCode)))
            }
        } else {
            complete(with: .failure(.networkError(error.localizedDescription, statusCode: statusCode)))
        }
    }
}

enum NetworkHelper {
    
    /// Downloads a file from URL directly to the specified destination path.
    ///
    /// Used for iOS Documents saves where we can write directly to the final location.
    ///
    /// - Parameters:
    ///   - urlString: The URL to download from
    ///   - headers: Optional HTTP headers as dictionary
    ///   - timeoutSeconds: Timeout in seconds
    ///   - destinationURL: The file URL to save the download to
    ///   - onProgress: Optional download progress callback (0.0 to 1.0)
    ///   - cancellationToken: Optional cancellation token
    ///   - onCancelHandlerReady: Callback to receive the cancel handler for direct task cancellation
    ///   - completion: Completion handler with Result containing total size or error
    static func downloadToFile(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        destinationURL: URL,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken?,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        completion: @escaping (Result<Int64, FileSaverError>) -> Void
    ) {
        performDownload(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            destinationURL: destinationURL,
            onProgress: onProgress,
            cancellationToken: cancellationToken,
            onCancelHandlerReady: onCancelHandlerReady
        ) { result in
            switch result {
            case .success(let (_, totalSize)):
                completion(.success(totalSize))
            case .failure(let error):
                completion(.failure(error))
            }
        }
    }
    
    /// Downloads a file from URL to a temporary file.
    ///
    /// Used for iOS Photos saves where we need a file URL to pass to PHPhotoLibrary.
    ///
    /// - Parameters:
    ///   - urlString: The URL to download from
    ///   - headers: Optional HTTP headers as dictionary
    ///   - timeoutSeconds: Timeout in seconds
    ///   - fileName: Name for the temporary file (including extension)
    ///   - onProgress: Optional download progress callback (0.0 to 1.0)
    ///   - cancellationToken: Optional cancellation token
    ///   - onCancelHandlerReady: Callback to receive the cancel handler for direct task cancellation
    ///   - completion: Completion handler with Result containing (temporary file URL, total size) or error
    static func downloadToTempFile(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        fileName: String,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken?,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        completion: @escaping (Result<(URL, Int64), FileSaverError>) -> Void
    ) {
        let tmpDir = FileManager.default.temporaryDirectory
        let tmpURL = tmpDir.appendingPathComponent(fileName)

        performDownload(
            urlString: urlString,
            headers: headers,
            timeoutSeconds: timeoutSeconds,
            destinationURL: tmpURL,
            onProgress: onProgress,
            cancellationToken: cancellationToken,
            onCancelHandlerReady: onCancelHandlerReady,
            completion: completion
        )
    }
    
    /// Parses a JSON string into a dictionary of HTTP headers.
    ///
    /// - Parameter headersJson: JSON string like {"key":"value"}, or nil
    /// - Returns: Dictionary of header key-value pairs, or nil if input is nil/empty
    static func parseHeaders(_ headersJson: String?) -> [String: String]? {
        guard let json = headersJson, !json.isEmpty else { return nil }
        
        guard let data = json.data(using: .utf8),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: String]
        else { return nil }
        
        return obj
    }
    
    // MARK: - Private

    private static func performDownload(
        urlString: String,
        headers: [String: String]?,
        timeoutSeconds: Int,
        destinationURL: URL,
        onProgress: ((Double) -> Void)?,
        cancellationToken: CancellationToken?,
        onCancelHandlerReady: @escaping (@escaping () -> Void) -> Void,
        completion: @escaping (Result<(URL, Int64), FileSaverError>) -> Void
    ) {
        guard let url = URL(string: urlString) else {
            completion(.failure(.networkError("Invalid URL: \(urlString)")))
            return
        }

        // Check cancellation before starting
        if let token = cancellationToken, token.isCancelled {
            completion(.failure(.cancelled))
            return
        }

        var request = URLRequest(url: url)
        request.httpMethod = "GET"
        request.timeoutInterval = TimeInterval(timeoutSeconds)

        headers?.forEach { key, value in
            request.setValue(value, forHTTPHeaderField: key)
        }

        var session: URLSession?
        var downloadTask: URLSessionDownloadTask?

        let delegate = DownloadDelegate(
            destinationURL: destinationURL,
            onProgress: onProgress,
            cancellationToken: cancellationToken,
            completion: { result in
                session?.finishTasksAndInvalidate()

                if let token = cancellationToken, token.isCancelled {
                    try? FileManager.default.removeItem(at: destinationURL)
                    completion(.failure(.cancelled))
                    return
                }

                completion(result)
            }
        )

        session = URLSession(
            configuration: .default,
            delegate: delegate,
            delegateQueue: nil
        )

        downloadTask = session!.downloadTask(with: request)
        downloadTask!.resume()

        // Provide cancel handler to caller for direct task cancellation
        onCancelHandlerReady {
            downloadTask?.cancel()
            session?.invalidateAndCancel()
        }
    }
}
