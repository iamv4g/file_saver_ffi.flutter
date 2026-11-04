import FileSaverDartApi
import Foundation

#if os(iOS)
import UIKit
import Photos
#elseif os(macOS)
import AppKit
#endif

/// `FileSaver` keeps no state between calls, so every call shares one.
private let fileSaver = FileSaver()

// MARK: - Operation Registry

/// A running one-shot save, which `file_saver_cancel` can cancel.
final class SaveOperation {
    let token = CancellationToken()
    private var cancelHandler: (() -> Void)?
    private let lock = NSLock()

    /// Sets the handler that stops the save's work in progress, such as a
    /// download task. Runs it at once if the operation is already cancelled.
    func setCancelHandler(_ handler: @escaping () -> Void) {
        lock.lock()
        cancelHandler = handler
        lock.unlock()
        if token.isCancelled { handler() }
    }

    /// Marks the operation cancelled and runs its cancel handler, if any.
    func cancel() {
        token.cancel()
        lock.lock()
        let handler = cancelHandler
        lock.unlock()
        handler?()
    }
}

private var operations: [UInt64: SaveOperation] = [:]
private var operationCounter: UInt64 = 0
private let operationLock = NSLock()

private func registerOperation(_ operation: SaveOperation) -> UInt64 {
    operationLock.lock()
    defer { operationLock.unlock() }
    operationCounter += 1
    operations[operationCounter] = operation
    return operationCounter
}

private func unregisterOperation(_ id: UInt64) {
    operationLock.lock()
    defer { operationLock.unlock() }
    operations.removeValue(forKey: id)
}

func cancelOperation(_ id: UInt64) {
    operationLock.lock()
    let operation = operations[id]
    operationLock.unlock()
    operation?.cancel()
}

/// Starts a one-shot save on a background queue, and returns its id for
/// `file_saver_cancel`.
///
/// Sends Started, then runs `save`, which must call `done` once the save has
/// ended. A save cancelled before it starts sends only Cancelled. Copy the C
/// arguments before calling this: they are only valid until the entry point
/// returns.
func runOperation(
    reporter: ProgressReporter,
    queue: DispatchQueue = .global(qos: .userInitiated),
    _ save: @escaping (_ operation: SaveOperation, _ done: @escaping () -> Void) -> Void
) -> UInt64 {
    let operation = SaveOperation()
    let id = registerOperation(operation)
    queue.async {
        let done = { unregisterOperation(id) }
        if operation.token.isCancelled {
            reporter.sendCancelled()
            return done()
        }
        reporter.sendStarted()
        save(operation, done)
    }
    return id
}

// MARK: - Write Session Registry

/// Receives the replies of write-session calls. `ProgressReporter` sends them
/// to Dart; tests record them.
protocol WriteSessionReporter {
    func sendBytes(_ bytes: Int64)
    func sendError(code: String, message: String)
    func sendSuccess(uri: String)
}

extension ProgressReporter: WriteSessionReporter {}

/// One `openWrite`/`openWriteAs` session. Every operation runs on
/// `serialQueue`, in the order it was called.
final class WriteSession {
    let fileHandle: FileHandle
    /// File the chunks are written to. Never an existing file: for `overwrite` it
    /// is a temp file, so `cancel` and a failed `close` can always delete it.
    let fileURL: URL
    let serialQueue: DispatchQueue
    let securityScopedURL: URL?  // non-nil for openWriteAs
    private(set) var bytesWritten: Int64 = 0
    /// Invoked on close: makes `fileURL` the saved file (replacing the
    /// original for `overwrite`, or adding it to the Photos Library) and returns
    /// the URI to report.
    let commit: () throws -> String
    /// The first write or flush error. Later writes and flushes report it
    /// again, and `close` deletes the file instead of committing it.
    private var failure: (code: String, message: String)?

    init(
        fileHandle: FileHandle,
        fileURL: URL,
        securityScopedURL: URL?,
        commit: @escaping () throws -> String
    ) {
        self.fileHandle = fileHandle
        self.fileURL = fileURL
        self.securityScopedURL = securityScopedURL
        self.commit = commit
        self.serialQueue = DispatchQueue(
            label: "com.iamv4g.file_saver.ws.\(fileURL.lastPathComponent)",
            qos: .userInitiated
        )
    }

    /// Appends `chunk` and reports the total bytes written.
    func write(_ chunk: Data, reporter: WriteSessionReporter) {
        serialQueue.async {
            if let failure = self.failure {
                return reporter.sendError(code: failure.code, message: failure.message)
            }
            do {
                try self.fileHandle.write(contentsOf: chunk)
                self.bytesWritten += Int64(chunk.count)
                reporter.sendBytes(self.bytesWritten)
            } catch {
                self.fail(FileHelper.ioError(error, url: self.fileURL), reporter: reporter)
            }
        }
    }

    /// Flushes the written data to storage and reports the total bytes written.
    func flush(reporter: WriteSessionReporter) {
        serialQueue.async {
            if let failure = self.failure {
                return reporter.sendError(code: failure.code, message: failure.message)
            }
            do {
                try self.fileHandle.synchronize()
                reporter.sendBytes(self.bytesWritten)
            } catch {
                self.fail(FileHelper.ioError(error, url: self.fileURL), reporter: reporter)
            }
        }
    }

    /// Closes the file and commits it, reporting its URI. If a write failed,
    /// or the file can't be closed or committed, deletes it and reports the
    /// error instead.
    func close(reporter: WriteSessionReporter) {
        serialQueue.async {
            // Commit while the security scope is still held: replacing a file in a
            // user-picked directory needs access to it.
            defer { self.securityScopedURL?.stopAccessingSecurityScopedResource() }

            if let failure = self.failure {
                self.closeHandle()
                self.deleteFile()
                return reporter.sendError(code: failure.code, message: failure.message)
            }
            do {
                try self.fileHandle.synchronize()
                try self.fileHandle.close()
            } catch {
                self.closeHandle()
                self.deleteFile()
                let failure = FileHelper.ioError(error, url: self.fileURL)
                return reporter.sendError(code: failure.code, message: failure.message)
            }
            do {
                reporter.sendSuccess(uri: try self.commit())
            } catch let fsError as FileSaverError {
                self.deleteFile()
                reporter.sendError(code: fsError.code, message: fsError.message)
            } catch {
                self.deleteFile()
                reporter.sendError(code: Constants.errorFileIO, message: error.localizedDescription)
            }
        }
    }

    /// Closes and deletes the file. Reports nothing.
    func cancel() {
        serialQueue.async {
            self.closeHandle()
            self.securityScopedURL?.stopAccessingSecurityScopedResource()
            self.deleteFile()
        }
    }

    private func fail(_ error: FileSaverError, reporter: WriteSessionReporter) {
        failure = (error.code, error.message)
        reporter.sendError(code: error.code, message: error.message)
    }

    private func closeHandle() {
        try? fileHandle.close()
    }

    private func deleteFile() {
        try? FileManager.default.removeItem(at: fileURL)
    }
}

private var writeSessionRegistry: [UInt64: WriteSession] = [:]
private let writeSessionLock = NSLock()
private var writeSessionIdCounter: UInt64 = 0

private func generateWriteSessionId() -> UInt64 {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    writeSessionIdCounter += 1
    return writeSessionIdCounter
}

private func registerWriteSession(_ id: UInt64, _ session: WriteSession) {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    writeSessionRegistry[id] = session
}

private func removeWriteSession(_ id: UInt64) -> WriteSession? {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    return writeSessionRegistry.removeValue(forKey: id)
}

private func getWriteSession(_ id: UInt64) -> WriteSession? {
    writeSessionLock.lock()
    defer { writeSessionLock.unlock() }
    return writeSessionRegistry[id]
}

@_cdecl("file_saver_init_dart_api_dl")
public func fileSaverInitDartApiDL(_ data: UnsafeMutableRawPointer?) -> Int {
    guard let data = data else { return -1 }
    return FileSaver_InitializeApiDL(data)
}

@_cdecl("file_saver_cancel")
public func fileSaverCancel(_ operationId: UInt64) {
    cancelOperation(operationId)
}

@_cdecl("file_saver_save_bytes")
public func fileSaverSaveBytes(
    _ fileData: UnsafeMutablePointer<UInt8>,
    _ fileDataLength: Int64,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt64 {
    // Takes ownership of the buffer: it is freed with the Data.
    let data = Data(bytesNoCopy: fileData, count: Int(fileDataLength), deallocator: .free)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        defer { done() }
        fileSaver.saveBytes(
            fileData: data,
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token
        )
    }
}

@_cdecl("file_saver_save_file")
public func fileSaverSaveFile(
    _ filePath: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt64 {
    let path = String(cString: filePath)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        defer { done() }
        fileSaver.saveFile(
            filePath: path,
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token
        )
    }
}

@_cdecl("file_saver_save_network")
public func fileSaverSaveNetwork(
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
) -> UInt64 {
    let url = String(cString: urlString)
    let headers = NetworkHelper.parseHeaders(headersJson.map { String(cString: $0) })
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mime = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        fileSaver.saveNetwork(
            urlString: url,
            headers: headers,
            timeoutSeconds: Int(timeoutSeconds),
            baseFileName: fileName,
            extension: extStr,
            mimeType: mime,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token,
            onCancelHandlerReady: operation.setCancelHandler,
            onComplete: done
        )
    }
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
        fileSaverPresentActivityVC([url], from: viewController)
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
    _ fileData: UnsafeMutablePointer<UInt8>,
    _ fileDataLength: Int64,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt64 {
    // Takes ownership of the buffer: it is freed with the Data.
    let data = Data(bytesNoCopy: fileData, count: Int(fileDataLength), deallocator: .free)
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        defer { done() }
        fileSaver.saveBytesAs(
            fileData: data,
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token
        )
    }
}

@_cdecl("file_saver_save_file_as")
public func fileSaverSaveFileAs(
    _ filePath: UnsafePointer<CChar>,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt64 {
    let path = String(cString: filePath)
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        defer { done() }
        fileSaver.saveFileAs(
            filePath: path,
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token
        )
    }
}

@_cdecl("file_saver_save_network_as")
public func fileSaverSaveNetworkAs(
    _ urlString: UnsafePointer<CChar>,
    _ headersJson: UnsafePointer<CChar>?,
    _ timeoutSeconds: Int32,
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) -> UInt64 {
    let url = String(cString: urlString)
    let headers = NetworkHelper.parseHeaders(headersJson.map { String(cString: $0) })
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    let reporter = ProgressReporter(port: nativePort)
    return runOperation(reporter: reporter) { operation, done in
        fileSaver.saveNetworkAs(
            urlString: url,
            headers: headers,
            timeoutSeconds: Int(timeoutSeconds),
            directoryUri: dirUri,
            baseFileName: fileName,
            extension: extStr,
            conflictMode: Int(conflictMode),
            reporter: reporter,
            cancellationToken: operation.token,
            onCancelHandlerReady: operation.setCancelHandler,
            onComplete: done
        )
    }
}

// MARK: - Streaming Write Session Functions

/// Opens a write session with `open` on a background queue, and reports its
/// id, "0" for a `skip` of an existing file, or the error.
func openSession(reporter: WriteSessionReporter, _ open: @escaping () throws -> WriteSession) {
    DispatchQueue.global(qos: .userInitiated).async {
        do {
            let session = try open()
            let sessionId = generateWriteSessionId()
            registerWriteSession(sessionId, session)
            reporter.sendSuccess(uri: String(sessionId))
        } catch FileSaverError.writeSessionSkipped {
            reporter.sendSuccess(uri: "0")
        } catch let fsError as FileSaverError {
            reporter.sendError(code: fsError.code, message: fsError.message)
        } catch {
            reporter.sendError(code: Constants.errorPlatform, message: error.localizedDescription)
        }
    }
}

@_cdecl("file_saver_open_write")
public func fileSaverOpenWrite(
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ mimeType: UnsafePointer<CChar>,
    _ saveLocation: Int32,
    _ subDir: UnsafePointer<CChar>?,
    _ conflictMode: Int32,
    _ nativePort: Int64
) {
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)
    let mimeStr = String(cString: mimeType)
    let directory = subDir.map { String(cString: $0) }

    openSession(reporter: ProgressReporter(port: nativePort)) {
        let result = try fileSaver.openWriteSession(
            baseFileName: fileName,
            extension: extStr,
            mimeType: mimeStr,
            subDir: directory,
            saveLocationValue: Int(saveLocation),
            conflictMode: Int(conflictMode)
        )
        return WriteSession(
            fileHandle: result.fileHandle,
            fileURL: result.fileURL,
            securityScopedURL: nil,
            commit: result.commit
        )
    }
}

@_cdecl("file_saver_open_write_as")
public func fileSaverOpenWriteAs(
    _ directoryUri: UnsafePointer<CChar>,
    _ baseFileName: UnsafePointer<CChar>,
    _ ext: UnsafePointer<CChar>,
    _ conflictMode: Int32,
    _ nativePort: Int64
) {
    let dirUri = String(cString: directoryUri)
    let fileName = String(cString: baseFileName)
    let extStr = String(cString: ext)

    openSession(reporter: ProgressReporter(port: nativePort)) {
        guard let dirURL = URL(string: dirUri) else {
            throw FileSaverError.invalidInput("Invalid directory URI: \(dirUri)")
        }
        // Held until the session is closed or cancelled.
        let isScoped = dirURL.startAccessingSecurityScopedResource()
        do {
            let (fileURL, fileHandle, commit) = try fileSaver.openWriteSessionAs(
                directoryUri: dirUri,
                baseFileName: fileName,
                extension: extStr,
                conflictMode: Int(conflictMode)
            )
            return WriteSession(
                fileHandle: fileHandle,
                fileURL: fileURL,
                securityScopedURL: isScoped ? dirURL : nil,
                commit: commit
            )
        } catch {
            if isScoped { dirURL.stopAccessingSecurityScopedResource() }
            throw error
        }
    }
}

@_cdecl("file_saver_write_chunk")
public func fileSaverWriteChunk(
    _ sessionId: UInt64,
    _ data: UnsafeMutablePointer<UInt8>,
    _ dataLength: Int64,
    _ nativePort: Int64
) {
    let reporter = ProgressReporter(port: nativePort)
    // Takes ownership of the buffer: it is freed with the Data.
    let chunk = Data(bytesNoCopy: data, count: Int(dataLength), deallocator: .free)

    guard let session = getWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.write(chunk, reporter: reporter)
}

@_cdecl("file_saver_flush_write")
public func fileSaverFlushWrite(_ sessionId: UInt64, _ nativePort: Int64) {
    let reporter = ProgressReporter(port: nativePort)
    guard let session = getWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.flush(reporter: reporter)
}

@_cdecl("file_saver_close_write")
public func fileSaverCloseWrite(_ sessionId: UInt64, _ nativePort: Int64) {
    let reporter = ProgressReporter(port: nativePort)
    guard let session = removeWriteSession(sessionId) else {
        reporter.sendError(code: Constants.errorInvalidInput, message: "Session not found: \(sessionId)")
        return
    }
    session.close(reporter: reporter)
}

@_cdecl("file_saver_cancel_write")
public func fileSaverCancelWrite(_ sessionId: UInt64) {
    removeWriteSession(sessionId)?.cancel()
}
