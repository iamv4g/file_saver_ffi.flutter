import FileSaverDartApi
import XCTest

@testable import file_saver_ffi

/// Foundation has a `ProgressReporter` too (macOS 26).
private typealias ProgressReporter = file_saver_ffi.ProgressReporter

/// A message posted to the Dart port, decoded from its `Dart_CObject` array.
private enum Value: Equatable {
    case null
    case int(Int64)
    case double(Double)
    case string(String)
}

/// Records the messages a `ProgressReporter` posts, standing in for
/// `FileSaver_PostCObject_DL`. Thread-safe.
private final class Port {
    private let lock = NSLock()
    private var _messages: [[Value]] = []

    var messages: [[Value]] {
        lock.lock()
        defer { lock.unlock() }
        return _messages
    }

    /// The progress values posted, in order.
    var progress: [Double] {
        messages.compactMap { message in
            guard message.first == .int(1), case .double(let value) = message[1] else { return nil }
            return value
        }
    }

    func post(_ port: Int64, _ message: UnsafeMutablePointer<Dart_CObject>) -> Bool {
        let array = message.pointee.value.as_array
        let values = (0..<array.length).map { Self.decode(array.values[$0]!.pointee) }
        lock.lock()
        _messages.append(values)
        lock.unlock()
        return true
    }

    private static func decode(_ object: Dart_CObject) -> Value {
        switch object.type {
        case Dart_CObject_kInt64: return .int(object.value.as_int64)
        case Dart_CObject_kDouble: return .double(object.value.as_double)
        case Dart_CObject_kString: return .string(String(cString: object.value.as_string))
        default: return .null
        }
    }
}

final class ProgressReporterTests: XCTestCase {
    private let port = Port()
    private var time: TimeInterval = 0

    private func reporter() -> ProgressReporter {
        ProgressReporter(port: 1, post: port.post, now: { self.time })
    }

    // MARK: - Throttling

    func testProgressIsSentInStepsOfOnePercent() {
        let reporter = reporter()

        for i in 1...10_000 {
            reporter.sendProgress(Double(i) / 10_000)
        }

        let sent = port.progress
        XCTAssertLessThanOrEqual(sent.count, 101)
        XCTAssertGreaterThanOrEqual(sent.count, 100)
        XCTAssertEqual(sent.first, 0.0001)
        XCTAssertEqual(sent.last, 1.0)
        // Every step but the last one, to 1.0, is at least 1%.
        for (previous, next) in zip(sent, sent.dropFirst().dropLast()) {
            XCTAssertGreaterThanOrEqual(next - previous, ProgressReporter.minProgressStep - 1e-9)
        }
    }

    func testSmallerStepsAreSentAfter100Milliseconds() {
        let reporter = reporter()

        reporter.sendProgress(0.001)
        reporter.sendProgress(0.002)
        time += 0.05
        reporter.sendProgress(0.003)
        time += 0.05
        reporter.sendProgress(0.004)
        time += 0.2
        reporter.sendProgress(0.004)

        XCTAssertEqual(port.progress, [0.001, 0.004])
    }

    func testCompletionIsSentOnceAndNotDropped() {
        let reporter = reporter()

        reporter.sendProgress(0.995)
        reporter.sendProgress(1.0)
        reporter.sendProgress(1.0)
        reporter.sendProgress(1.5)

        XCTAssertEqual(port.progress, [0.995, 1.0])
    }

    // MARK: - Terminal events

    func testNothingIsSentAfterATerminalEvent() {
        let reporter = reporter()

        reporter.sendStarted()
        reporter.sendSuccess(uri: "file:///a.txt")
        reporter.sendProgress(1.0)
        reporter.sendBytes(1)
        reporter.sendError(code: "FILE_IO", message: "late")
        reporter.sendCancelled()

        XCTAssertEqual(port.messages, [[.int(0)], [.int(3), .string("file:///a.txt")]])
    }

    func testConcurrentTerminalEventsSendOnlyOne() {
        for _ in 0..<50 {
            let port = Port()
            let reporter = ProgressReporter(port: 1, post: port.post)

            DispatchQueue.concurrentPerform(iterations: 16) { i in
                switch i % 3 {
                case 0: reporter.sendSuccess(uri: "\(i)")
                case 1: reporter.sendError(code: "E", message: "\(i)")
                default: reporter.sendCancelled()
                }
                reporter.sendProgress(Double(i) / 16)
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
