import FileSaverDartApi
import XCTest

@testable import file_saver_ffi

/// Foundation has a `ProgressReporter` too (macOS 26).
private typealias ProgressReporter = file_saver_ffi.ProgressReporter

final class ProgressReporterTests: XCTestCase {
    private let port = RecordingPort()
    private var time: TimeInterval = 0

    private func reporter() -> ProgressReporter {
        ProgressReporter(port: 1, post: port.post, now: { self.time })
    }

    // MARK: - Throttling

    func testProgressIsSentInStepsOfOnePercent() {
        let reporter = reporter()

        for i in 1...10_000 {
            reporter.sendProgress(bytesWritten: Int64(i), totalBytes: 10_000)
        }

        let sent = port.progress
        XCTAssertLessThanOrEqual(sent.count, 101)
        XCTAssertGreaterThanOrEqual(sent.count, 100)
        XCTAssertEqual(sent.first, 1)
        XCTAssertEqual(sent.last, 10_000)
        // Every step but the last one, to the size, is at least 1%.
        for (previous, next) in zip(sent, sent.dropFirst().dropLast()) {
            XCTAssertGreaterThanOrEqual(next - previous, 100)
        }
    }

    func testSmallerStepsAreSentAfter100Milliseconds() {
        let reporter = reporter()

        reporter.sendProgress(bytesWritten: 1, totalBytes: 1000)
        reporter.sendProgress(bytesWritten: 2, totalBytes: 1000)
        time += 0.05
        reporter.sendProgress(bytesWritten: 3, totalBytes: 1000)
        time += 0.05
        reporter.sendProgress(bytesWritten: 4, totalBytes: 1000)
        time += 0.2
        reporter.sendProgress(bytesWritten: 4, totalBytes: 1000)

        XCTAssertEqual(port.progress, [1, 4])
    }

    func testCompletionIsSentOnceAndNotDropped() {
        let reporter = reporter()

        reporter.sendProgress(bytesWritten: 995, totalBytes: 1000)
        reporter.sendProgress(bytesWritten: 1000, totalBytes: 1000)
        reporter.sendProgress(bytesWritten: 1000, totalBytes: 1000)

        XCTAssertEqual(port.progress, [995, 1000])
    }

    func testAnUnknownSizeIsSentAsNullEvery100Milliseconds() {
        let reporter = reporter()

        reporter.sendProgress(bytesWritten: 1, totalBytes: nil)
        reporter.sendProgress(bytesWritten: 1_000_000, totalBytes: nil)
        time += 0.1
        reporter.sendProgress(bytesWritten: 1_000_001, totalBytes: nil)

        XCTAssertEqual(port.messages, [[.int(1), .int(1), .null], [.int(1), .int(1_000_001), .null]])
    }

    func testTheLastCountHeldBackIsSentBeforeSuccess() {
        let reporter = reporter()

        reporter.sendProgress(bytesWritten: 1, totalBytes: nil)
        reporter.sendProgress(bytesWritten: 2, totalBytes: nil)
        reporter.sendProgress(bytesWritten: 3, totalBytes: nil)
        reporter.sendSuccess(uri: "file:///a.txt")

        XCTAssertEqual(
            port.messages,
            [[.int(1), .int(1), .null], [.int(1), .int(3), .null], [.int(3), .string("file:///a.txt")]]
        )
    }

    func testACountAlreadySentIsNotSentAgainBeforeSuccess() {
        let reporter = reporter()

        reporter.sendProgress(bytesWritten: 1, totalBytes: 2)
        reporter.sendProgress(bytesWritten: 1, totalBytes: 2)
        reporter.sendSuccess(uri: "file:///a.txt")

        XCTAssertEqual(port.messages, [[.int(1), .int(1), .int(2)], [.int(3), .string("file:///a.txt")]])
    }

    // MARK: - Terminal events

    func testNothingIsSentAfterATerminalEvent() {
        let reporter = reporter()

        reporter.sendStarted()
        reporter.sendSuccess(uri: "file:///a.txt")
        reporter.sendProgress(bytesWritten: 1, totalBytes: 1)
        reporter.sendBytes(1)
        reporter.sendError(code: "FILE_IO", message: "late")
        reporter.sendCancelled()

        XCTAssertEqual(port.messages, [[.int(0)], [.int(3), .string("file:///a.txt")]])
    }

    func testConcurrentTerminalEventsSendOnlyOne() {
        for _ in 0..<50 {
            let port = RecordingPort()
            let reporter = ProgressReporter(port: 1, post: port.post)

            DispatchQueue.concurrentPerform(iterations: 16) { i in
                switch i % 3 {
                case 0: reporter.sendSuccess(uri: "\(i)")
                case 1: reporter.sendError(code: "E", message: "\(i)")
                default: reporter.sendCancelled()
                }
                reporter.sendProgress(bytesWritten: Int64(i) + 1, totalBytes: 16)
            }

            let terminal = port.messages.filter { [.int(2), .int(3), .int(4)].contains($0[0]) }
            XCTAssertEqual(terminal.count, 1, "\(port.messages)")
            XCTAssertEqual(port.messages.last, terminal.first)
        }
    }

    func testErrorMessagesCarryCodeAndText() {
        reporter().sendError(code: "PERMISSION_DENIED", message: "Không có quyền")

        XCTAssertEqual(port.messages, [[.int(2), .string("PERMISSION_DENIED"), .string("Không có quyền")]])
    }

    func testANetworkErrorCarriesItsStatusCode() {
        reporter().sendError(.networkError("HTTP 404", statusCode: 404))

        XCTAssertEqual(port.messages, [[.int(2), .string("NETWORK_ERROR"), .string("HTTP 404"), .int(404)]])
    }

    func testOtherErrorsHaveNoStatusCode() {
        reporter().sendError(.fileExists("a.txt"))

        XCTAssertEqual(port.messages, [[.int(2), .string("FILE_EXISTS"), .string("a.txt")]])
    }
}

/// `FileSaver_InitializeApiDL`, given the `DartApi` struct that
/// `NativeApi.initializeApiDLData` points to.
final class DartApiDLTests: XCTestCase {
    private static let post: @convention(c) (Dart_Port, UnsafeMutablePointer<Dart_CObject>?) -> Bool = { _, _ in
        true
    }

    /// Calls `FileSaver_InitializeApiDL` with a `DartApi { int major; int minor;
    /// DartApiEntry* functions; }` whose only function is `Dart_PostCObject`.
    private func initialize(major: Int32, functions: [String] = ["Dart_PostCObject"]) -> Int {
        let names = functions.map { strdup($0)! }
        defer { names.forEach { free($0) } }

        // DartApiEntry { const char* name; void* function; }, ending with a null name.
        let entries = UnsafeMutablePointer<UnsafeMutableRawPointer?>.allocate(capacity: 2 * (names.count + 1))
        defer { entries.deallocate() }
        let function = unsafeBitCast(Self.post, to: UnsafeMutableRawPointer.self)
        for (i, name) in names.enumerated() {
            entries[2 * i] = UnsafeMutableRawPointer(name)
            entries[2 * i + 1] = function
        }
        entries[2 * names.count] = nil
        entries[2 * names.count + 1] = nil

        let api = UnsafeMutableRawPointer.allocate(
            byteCount: 8 + MemoryLayout<UnsafeRawPointer>.size,
            alignment: MemoryLayout<UnsafeRawPointer>.alignment
        )
        defer { api.deallocate() }
        api.storeBytes(of: major, toByteOffset: 0, as: Int32.self)
        api.storeBytes(of: 0, toByteOffset: 4, as: Int32.self)
        api.storeBytes(of: UnsafeMutableRawPointer(entries), toByteOffset: 8, as: UnsafeMutableRawPointer.self)

        return FileSaver_InitializeApiDL(api)
    }

    func testAnotherMajorVersionIsRefused() {
        XCTAssertEqual(initialize(major: 1), -1)
        XCTAssertEqual(initialize(major: 3), -1)
    }

    func testMajorVersion2WithPostCObjectInitializes() {
        XCTAssertEqual(initialize(major: 2), 0)
    }

    func testAMissingPostCObjectIsRefused() {
        XCTAssertEqual(initialize(major: 2, functions: ["Dart_NewNativePort"]), -1)
    }
}
