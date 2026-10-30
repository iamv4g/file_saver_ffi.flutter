import FileSaverDartApi
import Foundation

/// Reports async operation results to Dart via NativePort (`FileSaver_PostCObject_DL`).
///
/// ## Message protocol
///
/// ### Used by `save()` / `saveAs()`
/// | Message              | Array sent                          |
/// |----------------------|-------------------------------------|
/// | Started              | `[0]`                               |
/// | Progress (0.0–1.0)   | `[1, Double]`  ← `sendProgress`     |
/// | Error                | `[2, errorCode, errorMessage]`      |
/// | Success              | `[3, fileUri]`                      |
/// | Cancelled            | `[4]`                               |
///
/// ### Used by write-session methods (`openWrite`, `writeChunk`, `flushWrite`, `closeWrite`)
/// | Message              | Array sent                          |
/// |----------------------|-------------------------------------|
/// | Chunk / flush ACK    | `[1, Int64(bytesWritten)]` ← `sendBytes` |
/// | Error                | `[2, errorCode, errorMessage]`      |
/// | Session opened       | `[3, sessionId]`                    |
/// | Session closed       | `[3, fileUri]`                      |
///
/// **Note**: `sendProgress` clamps to 0.0–1.0 and sends `Double`.
/// `sendBytes` sends raw `Int64` — Dart reads it as `(msg[1] as num).toInt()`.
///
/// Progress is throttled: a value is sent when it is 1.0, has grown by at least
/// 1% since the last one sent, or has grown and 100 ms have passed. A network
/// download reports thousands of values per file.
///
/// Every method can be called from any thread. Nothing is sent after a
/// terminal event (error, success, cancelled).
final class ProgressReporter {
    /// Posts a message to a Dart port. Tests replace `FileSaver_PostCObject_DL`.
    typealias Post = (Int64, UnsafeMutablePointer<Dart_CObject>) -> Bool

    static let minProgressStep = 0.01
    static let minProgressInterval: TimeInterval = 0.1

    private let port: Int64
    private let post: Post
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var isClosed = false
    private var lastProgress = -1.0
    private var lastProgressTime: TimeInterval = 0

    init(
        port: Int64,
        post: @escaping Post = { FileSaver_PostCObject_DL($0, $1) },
        now: @escaping () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    ) {
        self.port = port
        self.post = post
        self.now = now
    }

    /// Send "started" event
    func sendStarted() {
        send { [createInt(0)] }
    }

    /// Send progress update. Value is clamped to 0.0–1.0, throttled, and sent as `Double`.
    /// Use `sendBytes` instead for write-session chunk/flush ACKs.
    func sendProgress(_ value: Double) {
        let clampedValue = max(0.0, min(1.0, value))
        send(when: { self.shouldSendProgress(clampedValue) }) {
            [createInt(1), createDouble(clampedValue)]
        }
    }

    /// Send error event
    func sendError(code: String, message: String) {
        send(closing: true) { [createInt(2), createString(code), createString(message)] }
    }

    /// Send success event. For `save()`/`saveAs()`: `uri` is the file URI.
    /// For write sessions: `uri` is the sessionId string (open) or file URI (close).
    func sendSuccess(uri: String) {
        send(closing: true) { [createInt(3), createString(uri)] }
    }

    /// Send chunk/flush ACK for streaming write sessions. Sends cumulative `bytesWritten` as `Int64`.
    /// Dart reads this as `(msg[1] as num).toInt()`.
    func sendBytes(_ bytes: Int64) {
        send { [createInt(1), createInt(bytes)] }
    }

    /// Send cancelled event
    func sendCancelled() {
        send(closing: true) { [createInt(4)] }
    }

    /// Sends the message `elements` builds unless a terminal event was sent or
    /// `condition` is false. Holding the lock while posting keeps messages in
    /// the order the calls took it, and nothing after the terminal one.
    private func send(
        closing: Bool = false,
        when condition: () -> Bool = { true },
        _ elements: () -> [UnsafeMutablePointer<Dart_CObject>]
    ) {
        lock.lock()
        defer { lock.unlock() }
        guard !isClosed, condition() else { return }
        if closing { isClosed = true }
        sendArray(elements())
    }

    /// Called with the lock held.
    private func shouldSendProgress(_ value: Double) -> Bool {
        let time = now()
        let send =
            value >= 1.0 && lastProgress < 1.0
            || value - lastProgress >= Self.minProgressStep
            || value > lastProgress && time - lastProgressTime >= Self.minProgressInterval
        if send {
            lastProgress = value
            lastProgressTime = time
        }
        return send
    }

    // MARK: - Private helpers

    private func sendArray(_ elements: [UnsafeMutablePointer<Dart_CObject>]) {
        // Create array of pointers
        let arrayPtr = UnsafeMutablePointer<UnsafeMutablePointer<Dart_CObject>?>.allocate(capacity: elements.count)
        defer { arrayPtr.deallocate() }

        for (index, element) in elements.enumerated() {
            arrayPtr[index] = element
        }

        // Create array CObject
        var arrayObject = Dart_CObject()
        arrayObject.type = Dart_CObject_kArray
        arrayObject.value.as_array.length = elements.count
        arrayObject.value.as_array.values = arrayPtr

        // Send to Dart
        _ = withUnsafeMutablePointer(to: &arrayObject) { post(port, $0) }

        // Clean up elements
        for element in elements {
            freeObject(element)
        }
    }

    private func createInt(_ value: Int64) -> UnsafeMutablePointer<Dart_CObject> {
        let obj = UnsafeMutablePointer<Dart_CObject>.allocate(capacity: 1)
        obj.pointee.type = Dart_CObject_kInt64
        obj.pointee.value.as_int64 = value
        return obj
    }

    private func createDouble(_ value: Double) -> UnsafeMutablePointer<Dart_CObject> {
        let obj = UnsafeMutablePointer<Dart_CObject>.allocate(capacity: 1)
        obj.pointee.type = Dart_CObject_kDouble
        obj.pointee.value.as_double = value
        return obj
    }

    private func createString(_ value: String) -> UnsafeMutablePointer<Dart_CObject> {
        let obj = UnsafeMutablePointer<Dart_CObject>.allocate(capacity: 1)
        if let cString = strdup(value) {
            obj.pointee.type = Dart_CObject_kString
            obj.pointee.value.as_string = UnsafePointer(cString)
        } else {
            // Out of memory: Dart receives null.
            obj.pointee.type = Dart_CObject_kNull
        }
        return obj
    }

    private func freeObject(_ obj: UnsafeMutablePointer<Dart_CObject>) {
        if obj.pointee.type == Dart_CObject_kString, let str = obj.pointee.value.as_string {
            free(UnsafeMutablePointer(mutating: str))
        }
        obj.deallocate()
    }
}
