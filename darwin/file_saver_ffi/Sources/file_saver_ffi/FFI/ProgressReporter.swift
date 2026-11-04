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
/// | Progress             | `[1, Int64(bytesWritten), Int64(totalBytes) or null]` ← `sendProgress` |
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
/// **Note**: `sendProgress` sends the size as null when it isn't known.
/// `sendBytes` sends raw `Int64` — Dart reads it as `(msg[1] as num).toInt()`.
///
/// Progress is throttled: a count is sent when it is the first, equals the
/// size, has grown by at least 1% of the size since the last one sent, or has
/// grown and 100 ms have passed. A network download reports thousands of
/// counts per file. A count held back is sent before success, so Dart always
/// gets the last one.
///
/// Every method can be called from any thread. Nothing is sent after a
/// terminal event (error, success, cancelled).
final class ProgressReporter {
    /// Posts a message to a Dart port. Tests replace `FileSaver_PostCObject_DL`.
    typealias Post = (Int64, UnsafeMutablePointer<Dart_CObject>) -> Bool

    static let minProgressInterval: TimeInterval = 0.1

    private let port: Int64
    private let post: Post
    private let now: () -> TimeInterval
    private let lock = NSLock()
    private var isClosed = false
    private var lastBytes: Int64 = 0
    private var lastProgressTime: TimeInterval?
    /// The last count not sent, by the throttle.
    private var heldBack: (bytesWritten: Int64, totalBytes: Int64?)?

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

    /// Sends the bytes written so far and the size, nil if unknown. Throttled.
    /// Use `sendBytes` instead for write-session chunk/flush ACKs.
    func sendProgress(bytesWritten: Int64, totalBytes: Int64?) {
        send(when: { self.shouldSendProgress(bytesWritten, totalBytes) }) {
            progressMessage(bytesWritten, totalBytes)
        }
    }

    /// Send error event
    func sendError(code: String, message: String) {
        send(closing: true) { [createInt(2), createString(code), createString(message)] }
    }

    /// Sends `error`, with the HTTP status of a network error as a fourth
    /// element: `[2, code, message, statusCode]`.
    func sendError(_ error: FileSaverError) {
        guard let statusCode = error.statusCode else {
            return sendError(code: error.code, message: error.message)
        }
        send(closing: true) {
            [createInt(2), createString(error.code), createString(error.message), createInt(Int64(statusCode))]
        }
    }

    /// Send success event. For `save()`/`saveAs()`: `uri` is the file URI.
    /// For write sessions: `uri` is the sessionId string (open) or file URI (close).
    /// Sends the progress the throttle held back first.
    func sendSuccess(uri: String) {
        send(closing: true) {
            if let (bytesWritten, totalBytes) = heldBack {
                heldBack = nil
                sendArray(progressMessage(bytesWritten, totalBytes))
            }
            return [createInt(3), createString(uri)]
        }
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

    /// Called with the lock held. A count no larger than the last one sent is
    /// never sent.
    private func shouldSendProgress(_ bytes: Int64, _ totalBytes: Int64?) -> Bool {
        guard bytes > lastBytes else { return false }
        let time = now()
        let send =
            lastProgressTime.map { time - $0 >= Self.minProgressInterval } ?? true
            || bytes == totalBytes
            || totalBytes.map { (bytes - lastBytes) * 100 >= $0 } ?? false
        if send {
            lastBytes = bytes
            lastProgressTime = time
            heldBack = nil
        } else {
            heldBack = (bytes, totalBytes)
        }
        return send
    }

    private func progressMessage(_ bytesWritten: Int64, _ totalBytes: Int64?) -> [UnsafeMutablePointer<Dart_CObject>] {
        [createInt(1), createInt(bytesWritten), totalBytes.map(createInt) ?? createNull()]
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

    private func createNull() -> UnsafeMutablePointer<Dart_CObject> {
        let obj = UnsafeMutablePointer<Dart_CObject>.allocate(capacity: 1)
        obj.pointee.type = Dart_CObject_kNull
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
