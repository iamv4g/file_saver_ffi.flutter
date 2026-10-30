import XCTest

@testable import file_saver_ffi

/// Records the replies of one write-session call, standing in for the Dart
/// port. Replies arrive on the session's queue.
private final class RecordingReporter: WriteSessionReporter {
    enum Event: Equatable {
        case bytes(Int64)
        case error(code: String, message: String)
        case success(uri: String)
    }

    private let replied = XCTestExpectation(description: "reply")
    private(set) var event: Event?

    func sendBytes(_ bytes: Int64) { record(.bytes(bytes)) }
    func sendError(code: String, message: String) { record(.error(code: code, message: message)) }
    func sendSuccess(uri: String) { record(.success(uri: uri)) }

    /// Waits for the reply and returns it.
    func await(_ test: XCTestCase) -> Event? {
        test.wait(for: [replied], timeout: 5)
        return event
    }

    private func record(_ event: Event) {
        XCTAssertNil(self.event, "a second reply: \(event)")
        self.event = event
        replied.fulfill()
    }
}

final class WriteSessionTests: XCTestCase {
    private var directory: URL!
    private var commits = 0

    override func setUpWithError() throws {
        directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WriteSessionTests-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        commits = 0
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: directory)
    }

    /// A session on a new file. With `failingWrites`, the handle is read-only,
    /// so writes fail like on a full or revoked volume.
    private func makeSession(
        failingWrites: Bool = false,
        commit: (() throws -> String)? = nil
    ) throws -> WriteSession {
        let fileURL = directory.appendingPathComponent("log.txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let handle = failingWrites
            ? try FileHandle(forReadingFrom: fileURL)
            : try FileHandle(forWritingTo: fileURL)
        return WriteSession(
            fileHandle: handle,
            fileURL: fileURL,
            totalSize: -1,
            securityScopedURL: nil,
            commit: commit ?? { [unowned self] in
                commits += 1
                return fileURL.absoluteString
            }
        )
    }

    private func write(_ bytes: [UInt8], to session: WriteSession) -> RecordingReporter.Event? {
        let reporter = RecordingReporter()
        session.write(Data(bytes), reporter: reporter)
        return reporter.await(self)
    }

    private func flush(_ session: WriteSession) -> RecordingReporter.Event? {
        let reporter = RecordingReporter()
        session.flush(reporter: reporter)
        return reporter.await(self)
    }

    private func close(_ session: WriteSession) -> RecordingReporter.Event? {
        let reporter = RecordingReporter()
        session.close(reporter: reporter)
        return reporter.await(self)
    }

    func testWritesChunksAndCommitsOnClose() throws {
        let session = try makeSession()

        XCTAssertEqual(write([1, 2, 3], to: session), .bytes(3))
        XCTAssertEqual(write([4, 5], to: session), .bytes(5))
        XCTAssertEqual(flush(session), .bytes(5))
        XCTAssertEqual(close(session), .success(uri: session.fileURL.absoluteString))

        XCTAssertEqual(commits, 1)
        XCTAssertEqual(try Data(contentsOf: session.fileURL), Data([1, 2, 3, 4, 5]))
    }

    func testCloseAfterAFailedWriteReportsTheErrorAndDeletesTheFile() throws {
        let session = try makeSession(failingWrites: true)

        let failed = write([1, 2, 3], to: session)
        guard case .error(let code, _) = failed else {
            return XCTFail("expected an error, got \(String(describing: failed))")
        }
        XCTAssertEqual(code, Constants.errorFileIO)

        XCTAssertEqual(close(session), failed)
        XCTAssertEqual(commits, 0, "a truncated file must not be committed")
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.fileURL.path))
    }

    func testWritesAndFlushesAfterAFailedWriteReportTheSameError() throws {
        let session = try makeSession(failingWrites: true)
        let failed = write([1], to: session)
        guard case .error = failed else {
            return XCTFail("expected an error, got \(String(describing: failed))")
        }

        XCTAssertEqual(write([2], to: session), failed)
        XCTAssertEqual(flush(session), failed)
    }

    func testAFailedCommitReportsItsErrorAndDeletesTheFile() throws {
        let session = try makeSession(commit: {
            throw FileSaverError.fileIO("Cannot move the file into place")
        })
        XCTAssertEqual(write([1], to: session), .bytes(1))

        let closed = close(session)

        XCTAssertEqual(
            closed,
            .error(code: Constants.errorFileIO, message: FileSaverError.fileIO("Cannot move the file into place").message)
        )
        XCTAssertFalse(FileManager.default.fileExists(atPath: session.fileURL.path))
    }

    func testCancelDeletesTheFile() throws {
        let session = try makeSession()
        XCTAssertEqual(write([1], to: session), .bytes(1))

        session.cancel()
        session.serialQueue.sync {}

        XCTAssertFalse(FileManager.default.fileExists(atPath: session.fileURL.path))
        XCTAssertEqual(commits, 0)
    }
}
