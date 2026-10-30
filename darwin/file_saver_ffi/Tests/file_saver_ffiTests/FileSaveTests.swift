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
            XCTAssertEqual((error as? FileSaverError)?.code, Constants.errorPermissionDenied, "\(error)")
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
            XCTAssertEqual((error as? FileSaverError)?.code, Constants.errorPermissionDenied, "\(error)")
        }
    }

    func testErrorsOfAFailedWriteAreTyped() {
        let url = directory.appendingPathComponent("a.txt")

        XCTAssertEqual(FileHelper.ioError(POSIXError(.ENOSPC), url: url).code, Constants.errorStorageFull)
        XCTAssertEqual(
            FileHelper.ioError(CocoaError(.fileWriteOutOfSpace), url: url).code,
            Constants.errorStorageFull
        )
        XCTAssertEqual(
            FileHelper.ioError(CocoaError(.fileWriteNoPermission), url: url).code,
            Constants.errorPermissionDenied
        )
    }

    // MARK: - saveAs

    /// A directory URL without a security scope (startAccessing… returns false),
    /// which the app can still write.
    func testSaveAsWritesWhenTheDirectoryHasNoSecurityScope() throws {
        var saved: String?

        try CustomFileSaver().saveBytesAs(
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
            try CustomFileSaver().saveBytesAs(
                fileData: Data("hello".utf8),
                directoryURL: directory,
                fileName: "a.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: nil
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, Constants.errorPermissionDenied, "\(error)")
        }
    }

    func testCancelledSaveAsLeavesNoFile() throws {
        let token = CancellationToken()
        token.cancel()

        XCTAssertThrowsError(
            try CustomFileSaver().saveBytesAs(
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
            try CustomFileSaver().saveFileAs(
                filePath: directory.appendingPathComponent("missing.txt").path,
                directoryURL: directory,
                fileName: "copy.txt",
                conflictResolution: .autoRename,
                onProgress: nil,
                onSuccess: { _ in },
                cancellationToken: nil
            )
        ) { error in
            XCTAssertEqual((error as? FileSaverError)?.code, Constants.errorFileNotFound, "\(error)")
        }

        XCTAssertEqual(try entries(), [])
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
