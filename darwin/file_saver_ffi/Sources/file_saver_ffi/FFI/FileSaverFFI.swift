import FileSaverDartApi
import Foundation

#if os(iOS)
import UIKit
import Photos
#elseif os(macOS)
import AppKit
#endif

private var instanceCounter: UInt = 0
private var instances: [UInt: FileSaver] = [:]
private let instanceLock = NSLock()

// MARK: - Cancellation Token Registry (for saveBytes, saveFile)

private var tokenCounter: UInt = 0
private var activeTokens: [UInt: CancellationToken] = [:]
private let tokenLock = NSLock()

private func generateTokenId() -> UInt {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    tokenCounter += 1
    return tokenCounter
}

private func registerToken(_ tokenId: UInt, _ token: CancellationToken) {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    activeTokens[tokenId] = token
}

private func unregisterToken(_ tokenId: UInt) {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    activeTokens.removeValue(forKey: tokenId)
}

private func getToken(_ tokenId: UInt) -> CancellationToken? {
    tokenLock.lock()
    defer { tokenLock.unlock() }
    return activeTokens[tokenId]
}

// MARK: - Active Download Registry (for saveNetwork)

/// Holds cancellation state and handler for an active network download operation.
/// Thread-safe to handle race condition when cancel() is called before cancelHandler is set.
private class ActiveDownload {
    let token: CancellationToken
    private var _cancelHandler: (() -> Void)?
    private let lock = NSLock()

    init(token: CancellationToken) {
        self.token = token
    }

    /// Thread-safe setter for cancelHandler.
    /// If cancel() was already called, executes handler immediately.
    func setCancelHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        _cancelHandler = handler
        let alreadyCancelled = token.isCancelled
        lock.unlock()

        if alreadyCancelled {
            handler()
        }
    }

    /// Thread-safe cancel.
    /// Sets token.isCancelled and calls handler if available.
    func cancel() {
        token.cancel()

        lock.lock()
        let handler = _cancelHandler
        lock.unlock()

        handler?()
    }
}

private var activeDownloads: [UInt: ActiveDownload] = [:]
private let downloadLock = NSLock()

private func registerDownload(_ id: UInt, _ download: ActiveDownload) {
    downloadLock.lock()
    defer { downloadLock.unlock() }
    activeDownloads[id] = download
}

private func getDownload(_ id: UInt) -> ActiveDownload? {
    downloadLock.lock()
    defer { downloadLock.unlock() }
    return activeDownloads[id]
}

private func unregisterDownload(_ id: UInt) {
    downloadLock.lock()
    defer { downloadLock.unlock() }
    activeDownloads.removeValue(forKey: id)
}

// MARK: - Write Session Registry

private final class WriteSession {
    let fileHandle: FileHandle
    let fileURL: URL
    let totalSize: Int64  // -1 if unknown
    let serialQueue: DispatchQueue
    let securityScopedURL: URL?  // non-nil for openWriteAs
    var bytesWritten: Int64 = 0
    #if os(iOS)
    /// Non-nil when writing to Photos Library (iOS only).
    /// Invoked on closeWrite to commit the temp file and return `ph://` URI.
    let photosCommit: (() throws -> String)?
    #endif

    init(
        fileHandle: FileHandle,
        fileURL: URL,
        totalSize: Int64,
        securityScopedURL: URL?,
        photosCommit: (() throws -> String)? = nil
    ) {
        self.fileHandle = fileHandle
        self.fileURL = fileURL
        self.totalSize = totalSize
        self.securityScopedURL = securityScopedURL
        #if os(iOS)
        self.photosCommit = photosCommit
        #endif
        self.serialQueue = DispatchQueue(
            label: "com.vanvixi.file_saver.ws.\(fileURL.lastPathComponent)",
            qos: .userInitiated
        )
    }
}

private var writeSessionRegistry: [UInt: WriteSession] = [:]
private let writeSessionLock = NSLock()
private var writeSessionIdCounter: UInt = 0

private func generateWriteSessionId() -> UInt {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    writeSessionIdCounter += 1
    return writeSessionIdCounter
}

private func registerWriteSession(_ id: UInt, _ session: WriteSession) {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    writeSessionRegistry[id] = session
}

private func removeWriteSession(_ id: UInt) -> WriteSession? {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    return writeSessionRegistry.removeValue(forKey: id)
}

private func getWriteSession(_ id: UInt) -> WriteSession? {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    return writeSessionRegistry[id]
}

@_cdecl("file_saver_init_dart_api_dl")
public func fileSaverInitDartApiDL(_ data: UnsafeMutableRawPointer?) -> Int {
    guard let data = data else { return -1 }
    return FileSaver_InitializeApiDL(data)
}

@_cdecl("file_saver_init")
public func fileSaverInit() -> UInt {
    instanceLock.lock()
    defer { instanceLock.unlock() }

    instanceCounter += 1
    let id = instanceCounter
    instances[id] = FileSaver()

    return id
}

@_cdecl("file_saver_dispose")
public func fileSaverDispose(_ instanceId: UInt) {
    instanceLock.lock()
    defer { instanceLock.unlock() }

    instances.removeValue(forKey: instanceId)
}

@_cdecl("file_saver_cancel")
public func fileSaverCancel(_ tokenId: UInt) {
    // Try to cancel as download first (saveNetwork)
    if let download = getDownload(tokenId) {
        download.cancel()
        return
    }
    // Fall back to token cancellation (saveBytes, saveFile)
    getToken(tokenId)?.cancel()
}

@_cdecl("file_saver_save_bytes")
public func fileSaverSaveBytes(
    _ instanceId: UInt,
    _ fileData: UnsafePointer<UInt8>,
    _ fileDataLength: Int64,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create cancellation token
    let tokenId = generateTokenId()
    let token = CancellationToken()
    registerToken(tokenId, token)

    // Copy data before async operation (must be done synchronously)
    let data = Data(bytes: fileData, count: Int(fileDataLength))
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    DispatchQueue.global(qos: .userInitiated).async {
        defer { unregisterToken(tokenId) }

        // Send started event
        reporter.sendStarted()

        // Get FileSaver instance
        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            return
        }
        instanceLock.unlock()

        // Perform save with progress and cancellation support
        saver.saveBytes(
            fileData: data,
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token
        )
    }

    return tokenId
}

@_cdecl("file_saver_save_file")
public func fileSaverSaveFile(
    _ instanceId: UInt,
    _ filePath: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create cancellation token
    let tokenId = generateTokenId()
    let token = CancellationToken()
    registerToken(tokenId, token)

    // Copy strings before async operation (must be done synchronously)
    let path = String(cString: filePath)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    DispatchQueue.global(qos: .userInitiated).async {
        defer { unregisterToken(tokenId) }

        // Send started event
        reporter.sendStarted()

        // Get FileSaver instance
        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            return
        }
        instanceLock.unlock()

        // Perform save with progress and cancellation support
        saver.saveFile(
            filePath: path,
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token
        )
    }

    return tokenId
}

@_cdecl("file_saver_save_network")
public func fileSaverSaveNetwork(
    _ instanceId: UInt,
    _ urlString: UnsafePointer<CChar>,
    _ headersJson: UnsafePointer<CChar>?,
    _ timeoutSeconds: Int32,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create active download entry (holds token + cancel handler)
    let tokenId = generateTokenId()
    let token = CancellationToken()
    let activeDownload = ActiveDownload(token: token)
    registerDownload(tokenId, activeDownload)

    // Copy strings (must be done synchronously before returning)
    let url = String(cString: urlString)
    let headers = headersJson.map { String(cString: $0) }
    let timeout = Int(timeoutSeconds)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    DispatchQueue.global(qos: .userInitiated).async {
        // Get FileSaver instance
        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            unregisterDownload(tokenId)
            return
        }
        instanceLock.unlock()

        // Check if already cancelled before starting
        if token.isCancelled {
            reporter.sendCancelled()
            unregisterDownload(tokenId)
            return
        }

        // Send started event
        reporter.sendStarted()

        // Parse headers from JSON string
        let parsedHeaders = NetworkHelper.parseHeaders(headers)

        // Perform save
        saver.saveNetwork(
            urlString: url,
            headers: parsedHeaders,
            timeoutSeconds: timeout,
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token,
            onCancelHandlerReady: { cancelHandler in
                activeDownload.setCancelHandler(cancelHandler)
            },
            onComplete: {
                unregisterDownload(tokenId)
            }
        )
    }

    return tokenId
}

// MARK: - Open File helpers

#if os(iOS)
/// Returns the topmost presented view controller, used as the presenter for previews and share sheets.
private func fileSaverTopViewController() -> UIViewController? {
    guard
        let scene = UIApplication.shared.connectedScenes
            .first(where: { $0.activationState == .foregroundActive }) as? UIWindowScene,
        let window = scene.windows.first(where: { $0.isKeyWindow })
    else { return nil }

    var topVC = window.rootViewController
    while let presented = topVC?.presentedViewController {
        topVC = presented
    }
    return topVC
}

/// Delegate for UIDocumentInteractionController — retains the controller and supplies the presenter.
private final class FileSaverDocumentDelegate: NSObject, UIDocumentInteractionControllerDelegate {
    // Retained until preview is dismissed.
    var docController: UIDocumentInteractionController?

    func documentInteractionControllerViewControllerForPreview(
        _ controller: UIDocumentInteractionController
    ) -> UIViewController {
        return fileSaverTopViewController() ?? UIViewController()
    }

    func documentInteractionControllerDidEndPreview(
        _ controller: UIDocumentInteractionController
    ) {
        docController = nil  // release
    }
}

// Held strongly so the delegate isn't deallocated while the preview is open.
private var _fileSaverDocDelegate: FileSaverDocumentDelegate?

/// Presents a QuickLook/system preview via UIDocumentInteractionController.
/// Falls back to UIActivityViewController if the preview cannot be shown.
private func fileSaverPresentPreview(url: URL, from viewController: UIViewController) {
    let delegate = FileSaverDocumentDelegate()
    let doc = UIDocumentInteractionController(url: url)
    delegate.docController = doc
    doc.delegate = delegate
    _fileSaverDocDelegate = delegate

    if !doc.presentPreview(animated: true) {
        _fileSaverDocDelegate = nil
        // Fallback: share sheet (e.g. for file types without a QuickLook preview)
        let activityVC = UIActivityViewController(activityItems: [url], applicationActivities: nil)
        if let popover = activityVC.popoverPresentationController {
            popover.sourceView = viewController.view
            popover.sourceRect = CGRect(
                x: viewController.view.bounds.midX,
                y: viewController.view.bounds.midY,
                width: 0,
                height: 0
            )
            popover.permittedArrowDirections = []
        }
        viewController.present(activityVC, animated: true)
    }
}

/// Fetches the underlying file URL from a ph:// Photos Library asset and opens a preview.
///
/// - Images: resolved via PHContentEditingInput.fullSizeImageURL
/// - Videos/audio: resolved via PHImageManager.requestAVAsset → AVURLAsset.url
private func fileSaverOpenPhAsset(_ localId: String, from viewController: UIViewController) {
    // Dart's Uri.parse() lowercases the host portion of URIs (ph://UUID/...).
    // iOS localIdentifiers use uppercase UUIDs, so we restore the original case.
    let fetchResult = PHAsset.fetchAssets(withLocalIdentifiers: [localId.uppercased()], options: nil)
    guard let asset = fetchResult.firstObject else { return }

    switch asset.mediaType {
    case .image:
        let options = PHContentEditingInputRequestOptions()
        options.isNetworkAccessAllowed = true
        asset.requestContentEditingInput(with: options) { input, _ in
            guard let fileURL = input?.fullSizeImageURL else { return }
            DispatchQueue.main.async {
                fileSaverPresentPreview(url: fileURL, from: viewController)
            }
        }

    case .video, .audio:
        PHImageManager.default().requestAVAsset(forVideo: asset, options: nil) { avAsset, _, _ in
            guard let urlAsset = avAsset as? AVURLAsset else { return }
            DispatchQueue.main.async {
                fileSaverPresentPreview(url: urlAsset.url, from: viewController)
            }
        }

    default:
        break
    }
}

/// Presents UIActivityViewController (share/open-with sheet) as a fallback when QuickLook preview is unavailable.
private func fileSaverPresentActivityVC(_ items: [Any], from viewController: UIViewController) {
    let activityVC = UIActivityViewController(activityItems: items, applicationActivities: nil)
    if let popover = activityVC.popoverPresentationController {
        popover.sourceView = viewController.view
        popover.sourceRect = CGRect(
            x: viewController.view.bounds.midX,
            y: viewController.view.bounds.midY,
            width: 0,
            height: 0
        )
        popover.permittedArrowDirections = []
    }
    viewController.present(activityVC, animated: true)
}
#endif

@_cdecl("file_saver_open_file")
public func fileSaverOpenFile(_ uriString: UnsafePointer<CChar>) -> Bool {
    let uri = String(cString: uriString)
    let work: () -> Bool = {
        #if os(iOS)
        guard let viewController = fileSaverTopViewController() else { return false }

        if uri.hasPrefix("ph://") {
            // ph:// is an internal Photos framework scheme — UIApplication.shared.open()
            // does not work with it. Resolve the underlying file URL via PHAsset and
            // show a QuickLook/system preview instead.
            let localId = String(uri.dropFirst("ph://".count))
            let fetchResult = PHAsset.fetchAssets(
                withLocalIdentifiers: [localId.uppercased()], options: nil
            )
            guard fetchResult.firstObject != nil else { return false }
            fileSaverOpenPhAsset(localId, from: viewController)
            return true
        } else if let url = URL(string: uri) {
            // Use UIDocumentInteractionController (QuickLook preview) for file:// URIs.
            // Falls back to UIActivityViewController for unsupported file types.
            fileSaverPresentPreview(url: url, from: viewController)
            return true
        }
        return false
        #elseif os(macOS)
        guard let url = URL(string: uri) else { return false }
        return NSWorkspace.shared.open(url)
        #endif
    }

    if Thread.isMainThread {
        return work()
    }
    return DispatchQueue.main.sync(execute: work)
}

@_cdecl("file_saver_can_open_file")
public func fileSaverCanOpenFile(_ uriString: UnsafePointer<CChar>) -> Bool {
    let uri = String(cString: uriString)
    #if os(iOS)
    if uri.hasPrefix("ph://") {
        let localId = String(uri.dropFirst("ph://".count))
        let fetchResult = PHAsset.fetchAssets(
            withLocalIdentifiers: [localId.uppercased()], options: nil
        )
        return fetchResult.firstObject != nil
    }
    #endif
    guard let url = URL(string: uri), url.isFileURL else { return false }
    return FileManager.default.isReadableFile(atPath: url.path)
}

@_cdecl("file_saver_save_bytes_as")
public func fileSaverSaveBytesAs(
    _ instanceId: UInt,
    _ fileData: UnsafePointer<UInt8>,
    _ fileDataLength: Int64,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create cancellation token
    let tokenId = generateTokenId()
    let token = CancellationToken()
    registerToken(tokenId, token)

    // Copy data before async operation
    let data = Data(bytes: fileData, count: Int(fileDataLength))
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    DispatchQueue.global(qos: .userInitiated).async {
        defer { unregisterToken(tokenId) }

        reporter.sendStarted()

        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            return
        }
        instanceLock.unlock()

        saver.saveBytesAs(
            fileData: data,
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token
        )
    }

    return tokenId
}

@_cdecl("file_saver_save_file_as")
public func fileSaverSaveFileAs(
    _ instanceId: UInt,
    _ filePath: UnsafePointer<CChar>,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create cancellation token
    let tokenId = generateTokenId()
    let token = CancellationToken()
    registerToken(tokenId, token)

    // Copy strings before async operation
    let path = String(cString: filePath)
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    DispatchQueue.global(qos: .userInitiated).async {
        defer { unregisterToken(tokenId) }

        reporter.sendStarted()

        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            return
        }
        instanceLock.unlock()

        saver.saveFileAs(
            filePath: path,
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token
        )
    }

    return tokenId
}

@_cdecl("file_saver_save_network_as")
public func fileSaverSaveNetworkAs(
    _ instanceId: UInt,
    _ urlString: UnsafePointer<CChar>,
    _ headersJson: UnsafePointer<CChar>?,
    _ timeoutSeconds: Int32,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt {
    let reporter = ProgressReporter(port: nativePort)

    // Create active download entry
    let tokenId = generateTokenId()
    let token = CancellationToken()
    let activeDownload = ActiveDownload(token: token)
    registerDownload(tokenId, activeDownload)

    // Copy strings
    let url = String(cString: urlString)
    let headers = headersJson.map { String(cString: $0) }
    let timeout = Int(timeoutSeconds)
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    DispatchQueue.global(qos: .userInitiated).async {
        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(
                code: Constants.errorPlatform,
                message: "FileSaver instance not found"
            )
            unregisterDownload(tokenId)
            return
        }
        instanceLock.unlock()

        if token.isCancelled {
            reporter.sendCancelled()
            unregisterDownload(tokenId)
            return
        }

        reporter.sendStarted()

        let parsedHeaders = NetworkHelper.parseHeaders(headers)

        saver.saveNetworkAs(
            urlString: url,
            headers: parsedHeaders,
            timeoutSeconds: timeout,
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: token,
            onCancelHandlerReady: { cancelHandler in
                activeDownload.setCancelHandler(cancelHandler)
            },
            onComplete: {
                unregisterDownload(tokenId)
            }
        )
    }

    return tokenId
}

// MARK: - Streaming Write Session Functions

@_cdecl("file_saver_open_write")
public func fileSaverOpenWrite(
    _ instanceId: UInt,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ totalSize: Int64,
    _ nativePort: Int64
) {
    let reporter = ProgressReporter(port: nativePort)
    // Copy strings synchronously before async block
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mimeStr = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    DispatchQueue.global(qos: .userInitiated).async {
        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            reporter.sendError(code: Constants.errorPlatform, message: "FileSaver instance not found")
            return
        }
        instanceLock.unlock()

        do {
            let result = try saver.openWriteSession(
                baseFileName: fileName,
                extension: extStr,
                mimeType: mimeStr,
                subDir: directory,
                saveLocationValue: Int(saveLocation),
                conflictMode: Int(conflictMode)
            )
            let sessionId = generateWriteSessionId()
            registerWriteSession(
                sessionId,
                WriteSession(
                    fileHandle: result.fileHandle,
                    fileURL: result.fileURL,
                    totalSize: totalSize,
                    securityScopedURL: nil,
                    photosCommit: result.photosCommit
                ))
            reporter.sendSuccess(uri: String(sessionId))
        } catch let fsError as FileSaverError {
            if case .writeSessionSkipped = fsError {
                reporter.sendSuccess(uri: "0")
                return
            }
            reporter.sendError(code: fsError.code, message: fsError.message)
        } catch {
            reporter.sendError(code: Constants.errorPlatform, message: error.localizedDescription)
        }
    }
}

@_cdecl("file_saver_open_write_as")
public func fileSaverOpenWriteAs(
    _ instanceId: UInt,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ totalSize: Int64,
    _ nativePort: Int64
) {
    let reporter = ProgressReporter(port: nativePort)
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    DispatchQueue.global(qos: .userInitiated).async {
        guard let dirURL = URL(string: dirUri) else {
            reporter.sendError(code: Constants.errorInvalidInput, message: "Invalid directory URI: \(dirUri)")
            return
        }
        let isScoped = dirURL.startAccessingSecurityScopedResource()

        instanceLock.lock()
        guard let saver = instances[instanceId] else {
            instanceLock.unlock()
            if isScoped { dirURL.stopAccessingSecurityScopedResource() }
            reporter.sendError(code: Constants.errorPlatform, message: "FileSaver instance not found")
            return
        }
        instanceLock.unlock()

        do {
            let (fileURL, fileHandle) = try saver.openWriteSessionAs(
                directoryUri: dirUri,
                baseFileName: fileName,
                extension: extStr,
                conflictMode: Int(conflictMode)
            )
            let sessionId = generateWriteSessionId()
            registerWriteSession(
                sessionId,
                WriteSession(
                    fileHandle: fileHandle,
                    fileURL: fileURL,
                    totalSize: totalSize,
                    securityScopedURL: isScoped ? dirURL : nil
                ))
            reporter.sendSuccess(uri: String(sessionId))
        } catch let fsError as FileSaverError {
            if case .writeSessionSkipped = fsError {
                if isScoped { dirURL.stopAccessingSecurityScopedResource() }
                reporter.sendSuccess(uri: "0")
                return
            }
            if isScoped { dirURL.stopAccessingSecurityScopedResource() }
            reporter.sendError(code: fsError.code, message: fsError.message)
        } catch {
            if isScoped { dirURL.stopAccessingSecurityScopedResource() }
            reporter.sendError(code: Constants.errorPlatform, message: error.localizedDescription)
        }
    }
}

@_cdecl("file_saver_write_chunk")
public func fileSaverWriteChunk(
    _ sessionId: UInt,
    _ data: UnsafePointer<UInt8>,
    _ dataLength: Int64,
    _ nativePort: Int64
) {
    let reporter = ProgressReporter(port: nativePort)
    // Copy data synchronously before returning — Dart arena freed after call
    let chunk = Data(bytes: data, count: Int(dataLength))

    guard let session = getWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.serialQueue.async {
        do {
            if #available(macOS 10.15.4, iOS 13.4, *) {
                try session.fileHandle.write(contentsOf: chunk)
            } else {
                session.fileHandle.write(chunk)
            }
            session.bytesWritten += Int64(chunk.count)
            reporter.sendBytes(session.bytesWritten)
        } catch {
            reporter.sendError(code: Constants.errorFileIO, message: error.localizedDescription)
        }
    }
}

@_cdecl("file_saver_flush_write")
public func fileSaverFlushWrite(_ sessionId: UInt, _ nativePort: Int64) {
    let reporter = ProgressReporter(port: nativePort)
    guard let session = getWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.serialQueue.async {
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try? session.fileHandle.synchronize()
        } else {
            session.fileHandle.synchronizeFile()
        }
        reporter.sendBytes(session.bytesWritten)
    }
}

@_cdecl("file_saver_close_write")
public func fileSaverCloseWrite(_ sessionId: UInt, _ nativePort: Int64) {
    let reporter = ProgressReporter(port: nativePort)
    guard let session = removeWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.serialQueue.async {
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try? session.fileHandle.synchronize()
            try? session.fileHandle.close()
        } else {
            session.fileHandle.synchronizeFile()
            session.fileHandle.closeFile()
        }
        session.securityScopedURL?.stopAccessingSecurityScopedResource()

        #if os(iOS)
        if let commit = session.photosCommit {
            do {
                let uri = try commit()
                reporter.sendSuccess(uri: uri)
            } catch let fsError as FileSaverError {
                reporter.sendError(code: fsError.code, message: fsError.message)
            } catch {
                reporter.sendError(code: Constants.errorFileIO, message: error.localizedDescription)
            }
            return
        }
        #endif

        reporter.sendSuccess(uri: session.fileURL.absoluteString)
    }
}

@_cdecl("file_saver_cancel_write")
public func fileSaverCancelWrite(_ sessionId: UInt) {
    guard let session = removeWriteSession(sessionId) else { return }
    session.serialQueue.async {
        if #available(macOS 10.15.4, iOS 13.4, *) {
            try? session.fileHandle.close()
        } else {
            session.fileHandle.closeFile()
        }
        session.securityScopedURL?.stopAccessingSecurityScopedResource()
        try? FileManager.default.removeItem(at: session.fileURL)
    }
}
