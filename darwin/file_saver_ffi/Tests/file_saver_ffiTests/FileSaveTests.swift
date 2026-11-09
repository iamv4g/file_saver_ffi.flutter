import XCTest

@testable import file_saver_ffi

/// Conflict resolution, file creation and source paths of FileManager saves,
/// in a temporary directory.
final class FileSaveTests: XCTestCase {
    private var directory: URL!

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("FileSaveTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }

    private func entries() throws -> [String] {
        try FileManager.default.contentsOfDirectory(atPath: directory.path).sorted()
    }

    private func touch(_ name: String) {
        FileManager.default.createFile(atPath: directory.appendingPathComponent(name).path, contents: Data("x".utf8))
    }

    private func resolve(_ name: String, _ resolution: ConflictResolution) throws -> FileSaveTarget {
        try FileManagerConflictResolver.resolveConflict(
            directory: directory,
            fileName: name,
            conflictResolution: resolution
        )
    }

    // MARK: - autoRename

    func testAutoRenameNumbersNamesWithoutAnExtension() throws {
        touch("notes")
        touch(".env")
        touch("archive.tar.gz")

        XCTAssertEqual(try resolve("notes", .autoRename).writeURL.lastPathComponent, "notes (1)")
        XCTAssertEqual(try resolve(".env", .autoRename).writeURL.lastPathComponent, ".env (1)")
        XCTAssertEqual(
            try resolve("archive.tar.gz", .autoRename).writeURL.lastPathComponent,
            "archive.tar (1).gz"
        )
    }

    func testConcurrentAutoRenamesPickDifferentNames() throws {
        touch("photo.jpg")
        let lock = NSLock()
        var names: [String] = []

        DispatchQueue.concurrentPerform(iterations: 20) { _ in
            let name = try? resolve("photo.jpg", .autoRename).writeURL.lastPathComponent
            lock.lock()
            names.append(name ?? "error")
            lock.unlock()
        }

        XCTAssertEqual(Set(names).count, 20, "\(names.sorted())")
        XCTAssertFalse(names.contains("error"))
    }

    // MARK: - Creating the file

    func testResolvingInADirectoryWithoutWriteAccessThrowsPermissionDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertThrowsError(try resolve("a.txt", .autoRename)) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, ErrorCode.permissionDenied, "\(error)")
        }
    }

    func testOpenWriteAsWithoutWriteAccessThrowsPermissionDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertThrowsError(
            try FileSaver().openWriteSessionAs(
                directoryUri: directory.absoluteString,
                baseFileName: "a",
                extension: "txt",
                conflictMode: ConflictResolution.autoRename.rawValue
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, ErrorCode.permissionDenied, "\(error)")
        }
    }

    func testErrorsOfAFailedWriteAreTyped() {
        let url = directory.appendingPathComponent("a.txt")

        XCTAssertEqual(FileHelper.ioError(POSIXError(.ENOSPC), url: url).code, ErrorCode.storageFull)
        XCTAssertEqual(
            FileHelper.ioError(CocoaError(.fileWriteOutOfSpace), url: url).code,
            ErrorCode.storageFull
        )
        XCTAssertEqual(
            FileHelper.ioError(CocoaError(.fileWriteNoPermission), url: url).code,
            ErrorCode.permissionDenied
        )
    }

    // MARK: - Downloads

    /// Downloads `path` of `server` into `directory` as `download.bin`.
    private func download(_ path: String, from server: TestHTTPServer) throws -> Result<URL, FileSaverError> {
        let done = expectation(description: "download")
        var result: Result<URL, FileSaverError>?
        SaveEngine().saveNetworkAs(
            urlString: server.url(path),
            headers: nil,
            timeoutSeconds: 10,
            directoryURL: directory,
            fileName: "download.bin",
            conflictResolution: .autoRename,
            onProgress: nil,
            onSuccess: { result = .success(URL(string: $0)!) },
            onError: { result = .failure($0) },
            onCancelled: { XCTFail("Cancelled") },
            onCancelHandlerReady: { _ in },
            onComplete: { done.fulfill() },
            cancellationToken: nil
        )
        wait(for: [done], timeout: 10)
        return try XCTUnwrap(result)
    }

    /// Makes another save of `download.bin` (with `autoRename`) run when a
    /// download ends, and returns where it saved.
    private func saveTheSameNameWhenADownloadEnds() -> () -> URL? {
        var saved: URL?
        NetworkHelper.beforeDownloadEnds = { [directory] in
            try? SaveEngine().saveBytesAs(
                fileData: Data("other".utf8),
                directoryURL: directory!,
                fileName: "download.bin",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { saved = URL(string: $0) },
                cancellationToken: nil
            )
        }
        addTeardownBlock { NetworkHelper.beforeDownloadEnds = nil }
        return { saved }
    }

    func testASaveOfTheSameNameWhileADownloadIsMovedIntoPlaceKeepsBothFiles() throws {
        let server = try TestHTTPServer(payload: Data("downloaded".utf8))
        defer { server.close() }
        let other = saveTheSameNameWhenADownloadEnds()

        let downloaded = try download("/sized", from: server).get()

        XCTAssertEqual(try Data(contentsOf: downloaded), server.payload)
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(other())), "other")
        XCTAssertEqual(try entries(), ["download (1).bin", "download.bin"])
    }

    func testASaveOfTheSameNameWhileADownloadFailsIsKept() throws {
        let server = try TestHTTPServer(payload: Data("downloaded".utf8))
        defer { server.close() }
        let other = saveTheSameNameWhenADownloadEnds()

        let result = try download("/truncated", from: server)

        guard case .failure(.networkError) = result else { return XCTFail("\(result)") }
        XCTAssertEqual(try String(contentsOf: XCTUnwrap(other())), "other")
        XCTAssertEqual(try entries(), ["download (1).bin"])
    }

    // MARK: - saveAs

    /// A directory URL without a security scope (startAccessing… returns false),
    /// which the app can still write.
    func testSaveAsWritesWhenTheDirectoryHasNoSecurityScope() throws {
        var saved: String?

        try SaveEngine().saveBytesAs(
            fileData: Data("hello".utf8),
            directoryURL: directory,
            fileName: "a.txt",
            conflictResolution: .autoRename,
            onProgress: nil,
            onSuccess: { saved = $0 },
            cancellationToken: nil
        )

        XCTAssertEqual(saved.flatMap(URL.init(string:))?.lastPathComponent, "a.txt")
        XCTAssertEqual(try String(contentsOf: directory.appendingPathComponent("a.txt")), "hello")
    }

    func testSaveAsWithoutWriteAccessThrowsPermissionDenied() throws {
        try FileManager.default.setAttributes([.posixPermissions: 0o555], ofItemAtPath: directory.path)

        XCTAssertThrowsError(
            try SaveEngine().saveBytesAs(
                fileData: Data("hello".utf8),
                directoryURL: directory,
                fileName: "a.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: nil
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, ErrorCode.permissionDenied, "\(error)")
        }
    }

    func testCancelledSaveAsLeavesNoFile() throws {
        let token = CancellationToken()
        token.cancel()

        XCTAssertThrowsError(
            try SaveEngine().saveBytesAs(
                fileData: Data("hello".utf8),
                directoryURL: directory,
                fileName: "a.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: token
            )
        )

        XCTAssertEqual(try entries(), [])
    }

    func testSaveFileAsOfAMissingSourceLeavesNoFile() throws {
        XCTAssertThrowsError(
            try SaveEngine().saveFileAs(
                filePath: directory.appendingPathComponent("missing.txt").path,
                directoryURL: directory,
                fileName: "copy.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: nil
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, ErrorCode.fileNotFound, "\(error)")
        }

        XCTAssertEqual(try entries(), [])
    }

    // MARK: - Error messages

    /// Dart builds the exception text from the detail, so the message must not
    /// carry a prefix of its own.
    func testErrorsSendOnlyTheDetailDartNeeds() throws {
        touch("a.txt")
        XCTAssertThrowsError(try resolve("a.txt", .fail)) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, ErrorCode.fileExists, "\(error)")
            XCTAssertEqual((error as? FileSaverError)?.message, "a.txt")
        }

        let missing = directory.appendingPathComponent("missing.txt").path
        XCTAssertThrowsError(
            try SaveEngine().saveFileAs(
                filePath: missing,
                directoryURL: directory,
                fileName: "copy.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: nil
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.message, missing)
        }

        XCTAssertEqual(FileSaverError.invalidInput("File data is empty").message, "File data is empty")
        XCTAssertEqual(FileSaverError.iCloudDownloadFailed("Timed out").message, "Timed out")
        XCTAssertEqual(FileSaverError.unsupportedFormat("heic").message, "heic")

        let network = FileSaverError.networkError("HTTP 404", statusCode: 404)
        XCTAssertEqual(network.message, "HTTP 404")
        XCTAssertEqual(network.statusCode, 404)
        XCTAssertNil(FileSaverError.networkError("No internet connection").statusCode)
    }

    // MARK: - Source paths

    func testSourcePathsKeepHashQuestionMarkAndPercent() throws {
        for name in ["a#1.txt", "b?.txt", "c%20d.txt"] {
            touch(name)
            let source = try FileHelper.openSourceFile(at: directory.appendingPathComponent(name).path)
            defer { source.close() }

            XCTAssertEqual(source.url.lastPathComponent, name)
            XCTAssertEqual(source.totalSize, 1)
        }
    }
}
