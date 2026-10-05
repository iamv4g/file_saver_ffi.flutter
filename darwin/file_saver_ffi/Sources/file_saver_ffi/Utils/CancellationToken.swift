import Foundation

/// Thread-safe cancellation token for async operations
final class CancellationToken {
    private let lock = NSLock()
    private var _isCancelled = false

    /// Check if the operation has been cancelled
    var isCancelled: Bool {
        lock.lock()
        defer { lock.unlock() }
        return _isCancelled
    }

    /// Cancel the operation
    func cancel() {
        lock.lock()
        defer { lock.unlock() }
        _isCancelled = true
    }

    /// Throw FileSaverError.cancelled if the operation was cancelled
    /// Call this at safe checkpoints (e.g., between chunk writes)
    func throwIfCancelled() throws {
        if isCancelled {
            throw FileSaverError.cancelled
        }
    }
}
