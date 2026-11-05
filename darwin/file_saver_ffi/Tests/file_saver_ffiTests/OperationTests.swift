import XCTest

@testable import file_saver_ffi

/// Foundation has a `ProgressReporter` too (macOS 26).
private typealias ProgressReporter = file_saver_ffi.ProgressReporter

/// How the FFI entry points run one-shot saves (`runOperation`) and open
/// write sessions (`openSession`).
final class OperationTests: XCTestCase {
    private let port = RecordingPort()

    private func reporter() -> ProgressReporter {
        ProgressReporter(port: 1, post: port.post)
    }

    // MARK: - runOperation

    func testASaveSendsStartedThenRuns() {
        let ran = expectation(description: "save")

        _ = runOperation(reporter: reporter()) { _, done in
            XCTAssertEqual(self.port.messages, [[.int(0)]])
            done()
            ran.fulfill()
        }

        wait(for: [ran], timeout: 5)
    }

    /// As a download always did: Dart gets Cancelled without Started.
    func testASaveCancelledBeforeItStartsSendsOnlyCancelledAndDoesNotRun() {
        let queue = DispatchQueue(label: "OperationTests")
        queue.suspend()
        let id = runOperation(reporter: reporter(), queue: queue) { _, done in
            XCTFail("The save ran")
            done()
        }

        fileSaverCancel(id)
        queue.resume()
        queue.sync {}

        XCTAssertEqual(port.messages, [[.int(4)]])
    }

    func testCancellingARunningSaveCancelsItsTokenAndRunsItsHandler() {
        let started = DispatchSemaphore(value: 0)
        let handlerRan = expectation(description: "cancel handler")
        var token: CancellationToken?
        let id = runOperation(reporter: reporter()) { operation, done in
            token = operation.token
            operation.setCancelHandler {
                handlerRan.fulfill()
                done()
            }
            started.signal()
        }
        XCTAssertEqual(started.wait(timeout: .now() + 5), .success)

        fileSaverCancel(id)

        wait(for: [handlerRan], timeout: 5)
        XCTAssertEqual(token?.isCancelled, true)
    }

    func testAnEndedSaveIsNoLongerCancelled() {
        let ended = expectation(description: "save")
        var token: CancellationToken?
        let id = runOperation(reporter: reporter()) { operation, done in
            token = operation.token
            done()
            ended.fulfill()
        }
        wait(for: [ended], timeout: 5)

        fileSaverCancel(id)

        XCTAssertEqual(token?.isCancelled, false)
    }

    func testEachSaveGetsItsOwnId() {
        let ids = (0..<3).map { _ in runOperation(reporter: reporter()) { _, done in done() } }

        XCTAssertEqual(Set(ids).count, 3)
    }

    // MARK: - SaveOperation

    /// A download sets its handler only once its task exists, which can be
    /// after the cancel.
    func testACancelHandlerSetAfterTheCancelRunsAtOnce() {
        let operation = SaveOperation()
        operation.cancel()
        var ran = false

        operation.setCancelHandler { ran = true }

        XCTAssertTrue(ran)
    }

    // MARK: - openSession

    private func open(_ make: @escaping () throws -> WriteSession) -> (code: Int64, data: PortValue?) {
        let replied = expectation(description: "reply")
        let reporter = ProgressReporter(
            port: 1,
            post: { [port] in
                defer { replied.fulfill() }
                return port.post($0, $1)
            })
        openSession(reporter: reporter, make)
        wait(for: [replied], timeout: 5)
        // The reply to this open, after those of earlier ones.
        let message = port.messages[port.messages.count - 1]
        guard case .int(let code) = message[0] else { return (-1, nil) }
        return (code, message.count > 1 ? message[1] : nil)
    }

    func testOpeningASessionReportsItsId() throws {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationTests-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        defer { try? FileManager.default.removeItem(at: fileURL) }
        let handle = try FileHandle(forWritingTo: fileURL)

        let reply = open {
            WriteSession(fileHandle: handle, fileURL: fileURL, securityScopedURL: nil, commit: { "" })
        }

        guard reply.code == 3, case .string(let id) = reply.data, let sessionId = UInt64(id) else {
            return XCTFail("\(reply)")
        }
        XCTAssertGreaterThan(sessionId, 0)
        fileSaverCancelWrite(sessionId)
    }

    /// Opens a session writing to a new temporary file, and returns its id,
    /// the session and the file.
    private func openTemporarySession() throws -> (id: UInt64, session: WriteSession, file: URL) {
        let fileURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("OperationTests-\(UUID().uuidString).txt")
        FileManager.default.createFile(atPath: fileURL.path, contents: nil)
        let session = WriteSession(
            fileHandle: try FileHandle(forWritingTo: fileURL),
            fileURL: fileURL,
            securityScopedURL: nil,
            commit: { "" }
        )
        let reply = open { session }
        guard reply.code == 3, case .string(let id) = reply.data, let sessionId = UInt64(id) else {
            throw XCTSkip("open replied \(reply)")
        }
        return (sessionId, session, fileURL)
    }

    func testFinalizingASessionDeletesItsFileAndPostsNothing() throws {
        let finalized = try openTemporarySession()
        let kept = try openTemporarySession()
        defer {
            fileSaverCancelWrite(kept.id)
            kept.session.serialQueue.sync {}
        }
        try finalized.session.fileHandle.write(contentsOf: Data("partial".utf8))
        let messagesBefore = port.messages.count

        fileSaverFinalizeWrite(UnsafeMutableRawPointer(bitPattern: UInt(finalized.id)))
        finalized.session.serialQueue.sync {}  // runs after the cancel it queued

        XCTAssertFalse(FileManager.default.fileExists(atPath: finalized.file.path))
        XCTAssertNil(getWriteSession(finalized.id))
        // The other session is untouched.
        XCTAssertNotNil(getWriteSession(kept.id))
        XCTAssertTrue(FileManager.default.fileExists(atPath: kept.file.path))
        // The callback runs without a Dart isolate, so it must not post.
        XCTAssertEqual(port.messages.count, messagesBefore)
    }

    func testFinalizingAnEndedSessionDoesNothing() throws {
        let ended = try openTemporarySession()
        fileSaverCancelWrite(ended.id)
        ended.session.serialQueue.sync {}

        fileSaverFinalizeWrite(UnsafeMutableRawPointer(bitPattern: UInt(ended.id)))
        fileSaverFinalizeWrite(nil)

        XCTAssertNil(getWriteSession(ended.id))
    }

    func testASkippedSessionReportsIdZero() {
        let reply = open { throw FileSaverError.writeSessionSkipped }

        XCTAssertEqual(reply.code, 3)
        XCTAssertEqual(reply.data, .string("0"))
    }

    func testAFailedOpenReportsItsError() {
        let reply = open { throw FileSaverError.permissionDenied("no access") }

        XCTAssertEqual(reply.code, 2)
        XCTAssertEqual(reply.data, .string(Constants.errorPermissionDenied))
    }
}
